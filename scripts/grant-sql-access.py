"""
Grants an Azure AD identity (e.g. a Web App's managed identity) db_datareader +
db_datawriter access to an Azure SQL Database, via CREATE USER ... FROM EXTERNAL
PROVIDER. This has no ARM/Terraform equivalent -- it's a data-plane T-SQL
operation, not a control-plane one -- so it runs as a post-apply pipeline step
instead (see null_resource.grant_app_sql_access in main.tf).

Authenticates using an Azure AD access token from whichever identity is already
logged in via `az login` (the pipeline's own OIDC-federated service principal in
CI, or a human's `az login` session when run locally) -- that identity must be
the SQL Server's Azure AD administrator for the CREATE USER statement to
succeed.

Whatever machine runs this (including the GitHub Actions runner itself) needs
its own IP allowed through the SQL firewall to connect at all, and that IP is
ephemeral -- same reason pre-allowlisting GitHub-hosted runner IP ranges doesn't
work (they're vast and change weekly). So this adds a temporary, single-IP
firewall rule scoped to whatever IP it's actually running from, does the work,
then removes it -- rather than requiring a static rule that would only work for
whichever machine happened to run this last.

Required environment variables:
  SQL_SERVER_FQDN     e.g. sql-demo-abcd1234.database.windows.net
  SQL_SERVER_NAME     e.g. sql-demo-abcd1234 (the resource name, not the FQDN)
  RESOURCE_GROUP_NAME e.g. rg-cloud-access-demo
  SQL_DATABASE        e.g. demodb
  APP_PRINCIPAL_NAME  the database user name to create, e.g. the Web App's
                      resource name (app-demo-abcd1234)
  APP_PRINCIPAL_ID    that principal's AAD object ID (GUID) -- used to build the
                      SID directly, avoiding a Microsoft Graph lookup (see the
                      comment on CREATE USER below for why that matters)
"""

import os
import shutil
import struct
import subprocess
import sys
import time
import urllib.request
import uuid

import pyodbc

SQL_COPT_SS_ACCESS_TOKEN = 1256


def az_cli() -> str:
    # shutil.which resolves the real executable (az.cmd on Windows, az on Linux/CI) --
    # subprocess.run with a bare "az" and no shell=True can't find batch-file extensions.
    az = shutil.which("az")
    if az is None:
        raise RuntimeError("az CLI not found on PATH")
    return az


def pick_odbc_driver() -> str:
    """Pick the newest installed SQL Server ODBC driver.

    Don't hardcode a version: a dev laptop and a GitHub-hosted runner don't
    necessarily ship the same one, and a missing-driver failure surfaces as an
    opaque pyodbc error rather than something actionable.
    """
    candidates = [d for d in pyodbc.drivers() if "SQL Server" in d]
    if not candidates:
        raise RuntimeError(
            f"No SQL Server ODBC driver installed. Available drivers: {pyodbc.drivers()}"
        )
    # "ODBC Driver 18 for SQL Server" sorts above 17 above the legacy "SQL Server".
    versioned = sorted(
        (d for d in candidates if "ODBC Driver" in d),
        key=lambda d: int("".join(c for c in d if c.isdigit()) or 0),
        reverse=True,
    )
    return versioned[0] if versioned else candidates[0]


def get_access_token(az: str) -> bytes:
    result = subprocess.run(
        [az, "account", "get-access-token", "--resource", "https://database.windows.net",
         "--query", "accessToken", "-o", "tsv"],
        capture_output=True, text=True, check=True,
    )
    token = result.stdout.strip()
    token_bytes = token.encode("utf-16-le")
    return struct.pack(f"<I{len(token_bytes)}s", len(token_bytes), token_bytes)


def get_own_public_ip() -> str:
    with urllib.request.urlopen("https://api.ipify.org", timeout=10) as resp:
        return resp.read().decode().strip()


def add_temp_firewall_rule(az: str, resource_group: str, server_name: str, ip: str, rule_name: str) -> None:
    subprocess.run(
        [az, "sql", "server", "firewall-rule", "create",
         "--resource-group", resource_group, "--server", server_name,
         "--name", rule_name, "--start-ip-address", ip, "--end-ip-address", ip],
        capture_output=True, text=True, check=True,
    )


def remove_temp_firewall_rule(az: str, resource_group: str, server_name: str, rule_name: str) -> None:
    subprocess.run(
        [az, "sql", "server", "firewall-rule", "delete",
         "--resource-group", resource_group, "--server", server_name, "--name", rule_name],
        capture_output=True, text=True, check=False,  # best-effort cleanup
    )


def connect_with_retry(conn_str: str, token_struct: bytes, attempts: int = 6, delay_seconds: int = 10):
    last_error = None
    for attempt in range(1, attempts + 1):
        try:
            return pyodbc.connect(conn_str, attrs_before={SQL_COPT_SS_ACCESS_TOKEN: token_struct})
        except pyodbc.Error as exc:
            last_error = exc
            print(f"Connect attempt {attempt}/{attempts} failed (firewall rule may still be "
                  f"propagating), retrying in {delay_seconds}s: {exc}")
            time.sleep(delay_seconds)
    raise last_error


def main() -> int:
    server_fqdn = os.environ["SQL_SERVER_FQDN"]
    server_name = os.environ["SQL_SERVER_NAME"]
    resource_group = os.environ["RESOURCE_GROUP_NAME"]
    database = os.environ["SQL_DATABASE"]
    principal = os.environ["APP_PRINCIPAL_NAME"]
    principal_id = os.environ["APP_PRINCIPAL_ID"]

    az = az_cli()
    my_ip = get_own_public_ip()
    rule_name = f"temp-grant-sql-access-{uuid.uuid4().hex[:8]}"

    print(f"Adding temporary firewall rule '{rule_name}' for {my_ip}...")
    add_temp_firewall_rule(az, resource_group, server_name, my_ip, rule_name)

    try:
        driver = pick_odbc_driver()
        print(f"Using ODBC driver: {driver}")
        conn_str = (
            f"DRIVER={{{driver}}};"
            f"SERVER={server_fqdn};DATABASE={database};Encrypt=yes;"
        )
        token_struct = get_access_token(az)
        conn = connect_with_retry(conn_str, token_struct)
        conn.autocommit = True
        cursor = conn.cursor()

        # Escaping: principal is a generated Azure resource name (alphanumerics + hyphens),
        # never user input, but bracket-escape defensively anyway since T-SQL identifiers
        # can't be parameterized.
        safe_principal = principal.replace("]", "]]")

        # Deliberately NOT "CREATE USER ... FROM EXTERNAL PROVIDER". That form makes
        # Azure SQL resolve the name against Microsoft Graph, and when the executing
        # identity is a service principal (our CI pipeline) rather than a human, the
        # SQL server's own identity needs the Directory Readers role to do that --
        # which requires a Global Admin to grant. Creating the user directly from its
        # AAD object ID as a SID needs no directory lookup at all, so it works
        # regardless of tenant permissions. TYPE = E marks it an external AAD principal.
        # bytes_le matches the mixed-endian byte order SQL Server expects for a GUID.
        sid = "0x" + uuid.UUID(principal_id).bytes_le.hex().upper()
        cursor.execute(
            f"IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ?) "
            f"CREATE USER [{safe_principal}] WITH SID = {sid}, TYPE = E",
            principal,
        )
        for role in ("db_datareader", "db_datawriter"):
            cursor.execute(
                f"IF NOT EXISTS ("
                f"  SELECT 1 FROM sys.database_role_members rm "
                f"  JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id "
                f"  JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id "
                f"  WHERE r.name = '{role}' AND m.name = ?"
                f") ALTER ROLE {role} ADD MEMBER [{safe_principal}]",
                principal,
            )

        conn.close()
        print(f"Granted {principal} db_datareader + db_datawriter on {database}.")
        return 0
    finally:
        print(f"Removing temporary firewall rule '{rule_name}'...")
        remove_temp_firewall_rule(az, resource_group, server_name, rule_name)


if __name__ == "__main__":
    sys.exit(main())
