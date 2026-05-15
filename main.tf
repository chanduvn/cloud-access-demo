terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state-demo"
    storage_account_name = "tfstatedemostorage2026" # Use your unique name
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

# 2. Create the Key Vault
resource "azurerm_key_vault" "vault" {
  name                = "kv-demo-${random_id.vault_id.hex}"
  location            = data.azurerm_resource_group.demo.location
  resource_group_name = data.azurerm_resource_group.demo.name
  tenant_id           = var.tenant_id
  sku_name            = "standard"
}

resource "random_id" "vault_id" {
  byte_length = 4
}

# 3. Add a secret to the vault (The "Secret Trap")
resource "azurerm_key_vault_secret" "example" {
  name         = "database-password"
  value        = "InitialStaticPassword123!"
  key_vault_id = azurerm_key_vault.vault.id
}