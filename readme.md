# Enterprise Azure CI/CD Pipeline with Terraform & GitHub Actions

This guide provides step-by-step instructions for establishing a secure, enterprise-grade Continuous Integration and Continuous Deployment (CI/CD) pipeline. It bridges GitHub Actions and Microsoft Azure using Terraform as the Infrastructure-as-Code (IaC) engine. 

This baseline introduces intentional security "traps" (e.g., hardcoded static secrets and manual approval gates tied to specific individuals) designed to be solved later by introducing governance and security tools like **One Identity Safeguard** and **Identity Manager**.

---

## Prerequisites

Before beginning, ensure you have the following ready:
1. **Azure Subscription**: An active subscription (e.g., Visual Studio Professional) with permissions to create Resource Groups, Storage Accounts, Key Vaults, and Role Assignments.
2. **GitHub Account**: A GitHub account to host the repository and run GitHub Actions.
3. **Local Tools**:
   - [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
   - [Terraform](https://developer.hashicorp.com/terraform/downloads)
   - [Git](https://git-scm.com/downloads)
   - A code editor (e.g., VS Code)

---

## Phase 1: Local Authentication & Resource Group Setup

First, authenticate your local terminal with Azure and create the primary target resource group where your application infrastructure will live.

1. Open your terminal (PowerShell/Bash) and log into Azure:
   ```bash
   az login
   ```
2. Set your active subscription (replace `<YOUR_SUBSCRIPTION_ID>` with your actual ID):
   ```bash
   az account set --subscription="<YOUR_SUBSCRIPTION_ID>"
   ```
3. Create the target resource group:
   ```bash
   az group create --name "rg-cloud-access-demo" --location "uksouth"
   ```

---

## Phase 2: Establish the "Bridge Identity" (Service Principal)

Your CI/CD pipeline needs a non-human identity (a Service Principal) to authenticate to Azure securely.

1. Create the Service Principal and assign it "Contributor" rights to your primary resource group:
   ```bash
   az ad sp create-for-rbac --name "Demo-Safeguard-Bridge-SP" --role Contributor --scopes /subscriptions/<YOUR_SUBSCRIPTION_ID>/resourceGroups/rg-cloud-access-demo
   ```
2. **Save the Output!** The command will return a JSON block. Securely save the `appId`, `password`, and `tenant` values. You will need them for GitHub Secrets.

---

## Phase 3: The Enterprise Foundation (Remote State)

Enterprise Terraform never stores its memory (`tfstate` file) locally. It must be locked in a central Azure Storage Account to prevent corruption and enable automation.

1. Create a dedicated resource group for the state file:
   ```bash
   az group create --name "rg-terraform-state-demo" --location "uksouth"
   ```
2. Create the Storage Account (the name must be globally unique; append random numbers if it fails):
   ```bash
   az storage account create --name "tfstatedemostorage001" --resource-group "rg-terraform-state-demo" --location "uksouth" --sku Standard_LRS
   ```
3. Create the Blob Container inside the storage account:
   ```bash
   az storage container create --name "tfstate" --account-name "tfstatedemostorage001"
   ```
4. **Critical Step (RBAC)**: Grant your new Service Principal permission to read/write to this state file resource group. Replace `<SP_OBJECT_ID>` with the Object ID of your Service Principal (found in Entra ID):
   ```bash
   az role assignment create --assignee "<SP_OBJECT_ID>" --role "Contributor" --scope "/subscriptions/<YOUR_SUBSCRIPTION_ID>/resourceGroups/rg-terraform-state-demo"
   ```

---

## Phase 4: GitHub Repository Configuration

Now, prepare your GitHub repository to securely store the code and enforce deployment rules.

1. **Create a Repository**: Create a new repository on GitHub.
   - *Note: If using a free GitHub account, set the repository visibility to **Public** to access Environment Protection rules.*
2. **Configure the Production Environment Gate**:
   - Go to **Settings > Environments** and create a new environment named `Production`.
   - Under **Environment protection rules**, check **Required reviewers**.
   - Add your own GitHub username as the reviewer. *(This establishes the "Approval Trap" that Identity Manager will later solve).*
3. **Configure GitHub Secrets**:
   - Go to **Settings > Secrets and variables > Actions**.
   - Add the following **Repository secrets** using the JSON output you saved in Phase 2:
     - `AZURE_CLIENT_ID`: (Your `appId`)
     - `AZURE_CLIENT_SECRET`: (Your `password`)
     - `AZURE_TENANT_ID`: (Your `tenant`)
     - `AZURE_SUBSCRIPTION_ID`: (Your Subscription ID)

---

## Phase 5: The Codebase

Set up your local repository to mirror your GitHub repository, and create the two foundational files.

### 1. The GitHub Actions Workflow
In your project folder, create the directory structure `.github/workflows/` and add a file named `terraform.yml`:

```yaml
name: 'Enterprise Terraform CI/CD'

on:
  push:
    branches: [ "main" ]
  pull_request:
    branches: [ "main" ]

env:
  ARM_CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
  ARM_CLIENT_SECRET: ${{ secrets.AZURE_CLIENT_SECRET }}
  ARM_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
  ARM_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}

jobs:
  terraform-plan:
    name: 'Terraform Plan (PR Check)'
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    steps:
    - uses: actions/checkout@v4
    - uses: hashicorp/setup-terraform@v3
    - name: Terraform Init
      run: terraform init
    - name: Terraform Plan
      run: terraform plan -no-color

  terraform-apply:
    name: 'Terraform Apply (Production)'
    runs-on: ubuntu-latest
    if: github.event_name == 'push'
    environment: Production
    steps:
    - uses: actions/checkout@v4
    - uses: hashicorp/setup-terraform@v3
    - name: Terraform Init
      run: terraform init
    - name: Terraform Apply
      run: terraform apply -auto-approve
```

### 2. The Terraform Configuration
In the root of your project folder, create `main.tf`. Be sure to update the `storage_account_name` to match the one you created in Phase 3:

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state-demo"
    storage_account_name = "tfstatedemostorage001" # Update this!
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

# The target resource group
resource "azurerm_resource_group" "demo" {
  name     = "rg-cloud-access-demo"
  location = "uksouth"
}

# Fetch the details of the currently logged-in identity (GitHub Actions SP)
data "azurerm_client_config" "current" {}

resource "random_id" "vault_id" {
  byte_length = 4
}

# Create the Key Vault
resource "azurerm_key_vault" "vault" {
  name                = "kv-demo-${random_id.vault_id.hex}"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Give the GitHub Actions Service Principal permission to write secrets
  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id
    secret_permissions = ["Get", "List", "Set", "Delete"]
  }
}

# The "Static Secret" Trap (To be solved by Safeguard)
resource "azurerm_key_vault_secret" "example" {
  name         = "database-password"
  value        = "InitialStaticPassword123!"
  key_vault_id = azurerm_key_vault.vault.id
}
```

---

## Phase 6: Execution & Validation

1. **Deploy to GitHub**:
   Run the following commands in your terminal to push your code:
   ```bash
   git add .
   git commit -m "feat: initial enterprise pipeline setup"
   git push origin main
   ```
2. **Review and Approve**:
   - Go to the **Actions** tab in your GitHub repository.
   - Click on the running workflow. It will pause at the `terraform-apply` stage.
   - Click **Review deployments**, check the `Production` box, and click **Approve and deploy**.
3. **Verify in Azure**:
   - Open the Azure Portal and navigate to `rg-cloud-access-demo`.
   - Click on the new Key Vault (`kv-demo-...`).
   - Navigate to **Objects > Secrets**.
   - *Note:* By default, you will not have permission to view the secret. You must go to **Settings > Access policies**, click **+ Create**, give yourself "Get" and "List" Secret permissions, and select your human Azure account as the Principal.
   - Once granted, you can view the `database-password` and see the hardcoded string `InitialStaticPassword123!`.

---

## Phase 7: Clean Teardown

To avoid state file conflicts (like Azure's Key Vault "Soft Delete" protections) and ensure your demo environment is wiped cleanly, **always tear down the infrastructure using code, never via the Azure Portal**.

From your local terminal:
1. Initialise the remote backend locally:
   ```bash
   terraform init
   ```
2. Destroy the infrastructure:
   ```bash
   terraform destroy -auto-approve
   ```
*(Note: Do not delete the `rg-terraform-state-demo` resource group. Leave the remote state backend intact so it is ready for your next deployment.)*