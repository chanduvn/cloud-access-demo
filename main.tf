terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
  
  # This tells Terraform to look in Azure for its memory, not the local disk
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state-demo"
    storage_account_name = "tfstatedemostorage001" # Update if you changed this
    container_name       = "tfstate"
    key                  = "prod.terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}

# The actual infrastructure we want to build
resource "random_id" "storage_id" {
  byte_length = 4
}

resource "azurerm_storage_account" "demo" {
  name                     = "prodstorage${random_id.storage_id.hex}"
  resource_group_name      = "rg-cloud-access-demo"
  location                 = "uksouth"
  account_tier             = "Standard"
  account_replication_type = "LRS"
}