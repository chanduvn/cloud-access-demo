terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state-demo"
    storage_account_name = "tfstatedemostorage001" # Ensure this matches your storage account
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
}

# 1. Fetch the Resource Group
data "azurerm_resource_group" "demo" {
  name = "rg-cloud-access-demo"
}

# NEW: Fetch the details of the currently logged-in identity (GitHub Actions SP)
data "azurerm_client_config" "current" {}

resource "random_id" "vault_id" {
  byte_length = 4
}

# 2. Create the Key Vault
resource "azurerm_key_vault" "vault" {
  name                = "kv-demo-${random_id.vault_id.hex}"
  location            = data.azurerm_resource_group.demo.location
  resource_group_name = data.azurerm_resource_group.demo.name
  
  # FIX: Dynamically assign the Tenant ID
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # FIX: Give the GitHub Actions Service Principal permission to write secrets to this vault
  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id
    secret_permissions = ["Get", "List", "Set", "Delete"]
  }
}

# 3. The "Static Secret" Trap
resource "azurerm_key_vault_secret" "example" {
  name         = "database-password"
  value        = "InitialStaticPassword123!"
  key_vault_id = azurerm_key_vault.vault.id
}