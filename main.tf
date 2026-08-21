terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state-demo"
    storage_account_name = "tfstatedemostorage001" # Your unique name
    container_name       = "tfstate"
    key                  = "prod.terraform.tfstate"
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
  skip_provider_registration = true
}

# CHANGED: Terraform will now CREATE this resource group if it doesn't exist
resource "azurerm_resource_group" "demo" {
  name     = "rg-cloud-access-demo"
  location = "uksouth"
}

data "azurerm_client_config" "current" {}

resource "random_id" "vault_id" {
  byte_length = 4
}

resource "azurerm_key_vault" "vault" {
  name                = "kv-demo-${random_id.vault_id.hex}"
  # Notice these now reference the 'resource' instead of 'data'
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Access policies are managed entirely via standalone azurerm_key_vault_access_policy
  # resources below (see terraform_operator, demo_operator, webapp_policy) — do not add
  # inline access_policy blocks here. Mixing both mechanisms on the same vault makes
  # Terraform lose track of which policy is which and can silently overwrite one
  # identity's permissions with another's on the next apply.
}

locals {
  # Fixed, stable identities — deliberately NOT data.azurerm_client_config.current.
  # Binding either policy to "whoever is currently running Terraform" made both
  # unstable across a human/CI identity switch: Key Vault access policies are keyed
  # by object_id, so every switch replaced the policy, and every replace risked a
  # collision with whatever policy already existed for the incoming object_id (hit
  # this for real, more than once, in both directions). Hardcoding both to their
  # real, permanent owners means neither ever needs to change just because a
  # different identity happened to run `terraform apply` this time.
  ci_pipeline_object_id   = "56081582-da15-4a25-91de-a5d275103958" # cloud-access-demo-oidc SP
  demo_operator_object_id = "39d8aa62-87be-4e64-9179-f0411bc70650" # human demo operator
}

# Access for the CI pipeline's identity specifically (not "whoever runs Terraform")
resource "azurerm_key_vault_access_policy" "terraform_operator" {
  key_vault_id       = azurerm_key_vault.vault.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = local.ci_pipeline_object_id
  secret_permissions = ["Get", "List", "Set", "Delete", "Purge"]
}

# Access for the demo operator (so terraform destroy/browsing works locally even
# when the vault was provisioned via CI)
resource "azurerm_key_vault_access_policy" "demo_operator" {
  key_vault_id       = azurerm_key_vault.vault.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = local.demo_operator_object_id
  secret_permissions = ["Get", "List", "Set", "Delete", "Purge"]
}

resource "azurerm_key_vault_secret" "example" {
  name         = "database-password"
  value        = "InitialStaticPassword123!"
  key_vault_id = azurerm_key_vault.vault.id

  # Only referencing azurerm_key_vault.vault.id doesn't force Terraform to wait for the
  # access policy that grants it write permission — the two aren't otherwise linked, so
  # they can run in parallel and this can lose the race against policy propagation.
  # Depends on both policies since either identity might be the one actually running
  # Terraform for a given apply/destroy.
  depends_on = [
    azurerm_key_vault_access_policy.terraform_operator,
    azurerm_key_vault_access_policy.demo_operator,
  ]
}

# ---------------------------------------------------------
# NEW: AZURE SQL SERVER & DATABASE
# ---------------------------------------------------------
resource "azurerm_mssql_server" "sql" {
  name                         = "sql-demo-${random_id.vault_id.hex}"
  resource_group_name          = azurerm_resource_group.demo.name
  location                     = "centralus"  # Most regions blocked for MSDN subs - centralus confirmed working
  version                      = "12.0"
  administrator_login          = "sqladmin"

  # ***** - this is the static password Safeguard will rotate later!
  administrator_login_password = azurerm_key_vault_secret.example.value

  # Azure AD administrator — required before any AAD-based CREATE USER FROM
  # EXTERNAL PROVIDER statement can run against a database on this server. Fixed
  # to the CI pipeline's identity (see locals.ci_pipeline_object_id above), same
  # reasoning as terraform_operator's Key Vault policy: this needs to be whoever
  # actually runs the grant_app_sql_access step in real operation (CI), not
  # whoever happens to be running `terraform apply` at any given moment.
  azuread_administrator {
    login_username = "terraform-pipeline-admin"
    object_id      = local.ci_pipeline_object_id
  }
}

resource "azurerm_mssql_database" "db" {
  name      = "demodb"
  server_id = azurerm_mssql_server.sql.id
  sku_name  = "Basic"
}

# Allow Azure Services (like our Web App) to reach the SQL Server
resource "azurerm_mssql_firewall_rule" "allow_azure" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.sql.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Allow the Safeguard appliance (Skytap egress IP) to reach the SQL Server for rotation
resource "azurerm_mssql_firewall_rule" "allow_safeguard" {
  name             = "AllowSafeguardAppliance"
  server_id        = azurerm_mssql_server.sql.id
  start_ip_address = "185.64.245.51"
  end_ip_address   = "185.64.245.51"
}


# ---------------------------------------------------------
# NEW: APP SERVICE (WEB APP)
# ---------------------------------------------------------
resource "azurerm_service_plan" "plan" {
  name                = "asp-demo-${random_id.vault_id.hex}"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  os_type             = "Linux"
  sku_name            = "B1" # Basic tier
}

# User-assigned rather than system-assigned, for one specific reason: Azure SQL
# identifies a service principal by its *application (client) ID*, so the database
# user's SID has to be built from that — not the object/principal ID. A
# system-assigned identity only exposes its principal_id through ARM; resolving that
# to a client ID needs a Microsoft Graph lookup, which requires directory read
# permissions the CI service principal doesn't have (the same Directory Readers wall
# that made us avoid CREATE USER ... FROM EXTERNAL PROVIDER). A user-assigned
# identity exposes client_id directly as a Terraform attribute, so the whole problem
# disappears. It also decouples identity lifecycle from the app's.
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-app-demo-${random_id.vault_id.hex}"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
}

resource "azurerm_linux_web_app" "app" {
  name                = "app-demo-${random_id.vault_id.hex}"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  service_plan_id     = azurerm_service_plan.plan.id

  site_config {
    application_stack {
      python_version = "3.9"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  # Key Vault references (if any are added later) must be resolved using the same
  # user-assigned identity; without this App Service looks for a system-assigned one.
  key_vault_reference_identity_id = azurerm_user_assigned_identity.app.id

  # No DB_PASSWORD: the app authenticates to SQL passwordlessly via its managed
  # identity (see grant_app_sql_access below) instead of a Key Vault-sourced secret.
  # AZURE_CLIENT_ID tells the ODBC driver *which* user-assigned identity to present —
  # unlike a system-assigned identity, that is not implicit.
  app_settings = {
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true" # Tells Azure to install python requirements
    "DB_SERVER"                      = azurerm_mssql_server.sql.fully_qualified_domain_name
    "DB_DATABASE"                    = azurerm_mssql_database.db.name
    "AZURE_CLIENT_ID"                = azurerm_user_assigned_identity.app.client_id
  }
}

# ---------------------------------------------------------
# NEW: GRANT WEB APP PERMISSION TO READ KEY VAULT
# ---------------------------------------------------------
# The web app no longer reads DB_PASSWORD from Key Vault (see app_settings above),
# but it keeps Get access — the sqladmin secret is still there for break-glass /
# Safeguard rotation, and this policy is cheap to leave in place for now.
resource "azurerm_key_vault_access_policy" "webapp_policy" {
  key_vault_id = azurerm_key_vault.vault.id
  tenant_id    = azurerm_user_assigned_identity.app.tenant_id
  object_id    = azurerm_user_assigned_identity.app.principal_id

  secret_permissions = ["Get"]
}

# ---------------------------------------------------------
# NEW: GRANT THE WEB APP'S MANAGED IDENTITY DATABASE ACCESS
# ---------------------------------------------------------
# No ARM/Terraform resource exists for "grant this AAD principal a role inside a
# SQL database" — CREATE USER ... FROM EXTERNAL PROVIDER is data-plane T-SQL, not
# a control-plane operation. Runs via the SQL AAD administrator identity above.
resource "null_resource" "grant_app_sql_access" {
  triggers = {
    client_id = azurerm_user_assigned_identity.app.client_id
    # Re-run whenever the script itself changes, not just when the identity does --
    # otherwise edits to the script silently never execute against an existing stack.
    script_hash = filemd5("${path.module}/scripts/grant-sql-access.py")
  }

  provisioner "local-exec" {
    command     = "python \"${path.module}/scripts/grant-sql-access.py\""
    interpreter = ["bash", "-c"]
    environment = {
      SQL_SERVER_FQDN     = azurerm_mssql_server.sql.fully_qualified_domain_name
      SQL_SERVER_NAME     = azurerm_mssql_server.sql.name
      RESOURCE_GROUP_NAME = azurerm_resource_group.demo.name
      SQL_DATABASE        = azurerm_mssql_database.db.name
      APP_PRINCIPAL_NAME  = azurerm_user_assigned_identity.app.name
      # The *client* ID, not the principal/object ID — see the comment on
      # azurerm_user_assigned_identity.app above.
      APP_CLIENT_ID = azurerm_user_assigned_identity.app.client_id
    }
  }

  depends_on = [
    azurerm_mssql_server.sql,
    azurerm_mssql_database.db,
    azurerm_mssql_firewall_rule.allow_azure,
  ]
}

# ---------------------------------------------------------
# OUTPUTS — used by the pipeline to pass values to scripts
# ---------------------------------------------------------
output "sql_server_fqdn" {
  description = "Fully qualified domain name of the Azure SQL Server"
  value       = azurerm_mssql_server.sql.fully_qualified_domain_name
}

output "db_username" {
  description = "SQL Server administrator login"
  value       = azurerm_mssql_server.sql.administrator_login
}

output "db_password" {
  description = "SQL Server administrator password (from Key Vault)"
  value       = azurerm_key_vault_secret.example.value
  sensitive   = true
}

output "web_app_name" {
  description = "Web App resource name — also its AAD login name for SQL access"
  value       = azurerm_linux_web_app.app.name
}