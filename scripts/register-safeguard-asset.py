"""
Register an Azure SQL Server as an asset and account in One Identity Safeguard.

Authentication uses a certificate user (PEM + KEY files), which is the recommended
method for non-human/CI-CD processes.

Required environment variables:
  SAFEGUARD_HOST       - Safeguard appliance hostname or IP, optionally with port.
                         Accepted formats:
                           services-emea.skytap.com          (default port 443)
                           services-emea.skytap.com:10097    (custom port)
                           https://services-emea.skytap.com  (https:// prefix is stripped)
  SAFEGUARD_CERT_FILE  - Path to the certificate .pem file for the cert user
  SAFEGUARD_KEY_FILE   - Path to the private key .key file for the cert user
  SAFEGUARD_CA_FILE    - Path to the appliance CA certificate for TLS verification
                         Set to 'insecure' to skip verification (dev/lab only)
  SQL_SERVER_FQDN      - Fully qualified domain name of the Azure SQL Server
                         e.g. sql-demo-xxxx.database.windows.net
  DB_USERNAME          - SQL Server administrator login name (e.g. sqladmin)
  DB_PASSWORD          - SQL Server administrator password to store in Safeguard
"""

import os
import sys

from pysafeguard import SafeguardClient, CertificateAuth, Service, ApiError


def get_required_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        print(f"ERROR: Required environment variable '{name}' is not set.")
        sys.exit(1)
    return value


def parse_host(raw: str) -> tuple[str, int]:
    """
    Parse SAFEGUARD_HOST into (hostname, port).
    Strips https:// or http:// prefix if present.
    Extracts port if specified (e.g. host:10097), defaults to 443.
    """
    host = raw.strip()
    # Strip scheme if someone included it
    for scheme in ("https://", "http://"):
        if host.lower().startswith(scheme):
            host = host[len(scheme):]
            break
    # Split host and optional port
    if ":" in host:
        hostname, port_str = host.rsplit(":", 1)
        try:
            port = int(port_str)
        except ValueError:
            print(f"ERROR: Invalid port in SAFEGUARD_HOST: '{port_str}'")
            sys.exit(1)
    else:
        hostname = host
        port = 443
    return hostname, port


def find_sql_platform(client: SafeguardClient) -> int:
    """Find the built-in SQL Server platform ID in Safeguard."""
    print("Looking up SQL Server platform...")
    platforms = client.get(
        Service.CORE,
        "Platforms",
        params={"filter": "Name contains 'SQL Server'", "fields": "Id,Name"}
    ).json()

    if not platforms:
        print("ERROR: No SQL Server platform found in Safeguard. "
              "Ensure the Safeguard appliance has a SQL Server platform configured.")
        sys.exit(1)

    # Prefer exact "SQL Server" match; fall back to first result
    for p in platforms:
        if p["Name"].strip().lower() == "sql server":
            print(f"  Found platform: '{p['Name']}' (Id={p['Id']})")
            return p["Id"]

    print(f"  Using first matching platform: '{platforms[0]['Name']}' (Id={platforms[0]['Id']})")
    return platforms[0]["Id"]


def find_or_create_asset(client: SafeguardClient, fqdn: str, platform_id: int) -> dict:
    """Find an existing asset by network address or create a new one."""
    print(f"Checking if asset '{fqdn}' already exists in Safeguard...")
    existing = client.get(
        Service.CORE,
        "Assets",
        params={"filter": f"NetworkAddress eq '{fqdn}'", "fields": "Id,Name,NetworkAddress"}
    ).json()

    if existing:
        asset = existing[0]
        print(f"  Asset already exists: '{asset['Name']}' (Id={asset['Id']}) — skipping creation.")
        return asset

    print(f"  Creating new asset for '{fqdn}'...")
    asset = client.post(Service.CORE, "Assets", json={
        "Name": fqdn,
        "NetworkAddress": fqdn,
        "PlatformId": platform_id,
        "Description": "Azure SQL Server — registered by CI/CD pipeline (cloud-access-demo)"
    }).json()
    print(f"  Asset created: '{asset['Name']}' (Id={asset['Id']})")
    return asset


def find_or_create_account(client: SafeguardClient, asset_id: int, username: str) -> dict:
    """Find an existing account on the asset or create a new one."""
    print(f"Checking if account '{username}' already exists on asset Id={asset_id}...")
    existing = client.get(
        Service.CORE,
        "AssetAccounts",
        params={
            "filter": f"Asset.Id eq {asset_id} and Name eq '{username}'",
            "fields": "Id,Name"
        }
    ).json()

    if existing:
        account = existing[0]
        print(f"  Account already exists: '{account['Name']}' (Id={account['Id']}) — skipping creation.")
        return account

    print(f"  Creating account '{username}'...")
    account = client.post(Service.CORE, "AssetAccounts", json={
        "AssetId": asset_id,
        "Name": username,
        "Description": "SQL admin account — managed by CI/CD pipeline"
    }).json()
    print(f"  Account created: '{account['Name']}' (Id={account['Id']})")
    return account


def set_account_password(client: SafeguardClient, account_id: int, password: str) -> None:
    """Store the password for the account in Safeguard's vault."""
    print(f"Setting password for account Id={account_id}...")
    client.put(Service.CORE, f"AssetAccounts/{account_id}/Password", data=password)
    print("  Password stored successfully.")


def main():
    host_raw    = get_required_env("SAFEGUARD_HOST")
    cert_file   = get_required_env("SAFEGUARD_CERT_FILE")
    key_file    = get_required_env("SAFEGUARD_KEY_FILE")
    ca_file_raw = get_required_env("SAFEGUARD_CA_FILE")
    fqdn        = get_required_env("SQL_SERVER_FQDN")
    username    = get_required_env("DB_USERNAME")
    password    = get_required_env("DB_PASSWORD")

    host, port = parse_host(host_raw)

    # 'insecure' disables TLS verification — only for dev/lab appliances
    verify = False if ca_file_raw.lower() == "insecure" else ca_file_raw
    if verify is False:
        print("WARNING: TLS certificate verification is DISABLED. "
              "Do not use 'insecure' in production.")

    print(f"\nConnecting to Safeguard appliance: {host}:{port}")
    print(f"  Certificate file : {cert_file}")
    print(f"  TLS verification : {'disabled' if verify is False else ca_file_raw}")
    print(f"  SQL Server FQDN  : {fqdn}")
    print(f"  DB username      : {username}\n")

    try:
        with SafeguardClient(host, port=port, auth=CertificateAuth(cert_file, key_file), verify=verify) as client:
            print("Connected to Safeguard.\n")

            platform_id = find_sql_platform(client)
            asset       = find_or_create_asset(client, fqdn, platform_id)
            account     = find_or_create_account(client, asset["Id"], username)
            set_account_password(client, account["Id"], password)

            print(f"\nDone. SQL Server '{fqdn}' is registered in Safeguard.")
            print(f"  Asset Id   : {asset['Id']}")
            print(f"  Account Id : {account['Id']}")

    except ApiError as e:
        print(f"\nSafeguard API error (HTTP {e.status_code}): {e.error_message}")
        sys.exit(1)


if __name__ == "__main__":
    main()
