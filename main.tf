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

# Access for whoever runs Terraform (Service Principal in CI)
resource "azurerm_key_vault_access_policy" "terraform_operator" {
  key_vault_id       = azurerm_key_vault.vault.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = data.azurerm_client_config.current.object_id
  secret_permissions = ["Get", "List", "Set", "Delete", "Purge"]
}

# Access for the demo operator (so terraform destroy works locally)
# IMPORTANT: Replace this Object ID with your own Azure AD User Object ID.
# Find yours by running: az ad signed-in-user show --query "id" -o tsv
resource "azurerm_key_vault_access_policy" "demo_operator" {
  key_vault_id       = azurerm_key_vault.vault.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = "39d8aa62-87be-4e64-9179-f0411bc70650"
  secret_permissions = ["Get", "List", "Set", "Delete", "Purge"]
}

resource "azurerm_key_vault_secret" "example" {
  name         = "database-password"
  value        = "InitialStaticPassword123!"
  key_vault_id = azurerm_key_vault.vault.id

  # Only referencing azurerm_key_vault.vault.id doesn't force Terraform to wait for the
  # access policy that grants it write permission — the two aren't otherwise linked, so
  # they can run in parallel and this can lose the race against policy propagation.
  # Depends on both policies: whichever identity actually runs Terraform (the CI service
  # principal in production, or a human's own identity when run locally — which happens
  # to collide with demo_operator's hardcoded object ID), its granting policy must still
  # exist when this resource is created or destroyed.
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

  # Give the Web App an Azure Active Directory Identity
  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true" # Tells Azure to install python requirements
    "DB_SERVER"                      = azurerm_mssql_server.sql.fully_qualified_domain_name
    "DB_DATABASE"                    = azurerm_mssql_database.db.name
    "DB_USERNAME"                    = azurerm_mssql_server.sql.administrator_login
    
    # THE MAGIC: Native Key Vault Reference. The App securely fetches this at runtime!
    "DB_PASSWORD"                    = "@Microsoft.KeyVault(VaultName=${azurerm_key_vault.vault.name};SecretName=${azurerm_key_vault_secret.example.name})"
  }
}

# ---------------------------------------------------------
# NEW: GRANT WEB APP PERMISSION TO READ KEY VAULT
# ---------------------------------------------------------
resource "azurerm_key_vault_access_policy" "webapp_policy" {
  key_vault_id = azurerm_key_vault.vault.id
  tenant_id    = azurerm_linux_web_app.app.identity[0].tenant_id
  object_id    = azurerm_linux_web_app.app.identity[0].principal_id

  secret_permissions = ["Get"]
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