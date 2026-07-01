# Cloud Access Demo — Two-Pipeline CI/CD with Terraform & GitHub Actions

This project deploys a Flask web application backed by Azure SQL, using two separate CI/CD pipelines:

| Pipeline | File | Purpose |
|---|---|---|
| **Day 0 — Infrastructure** | `.github/workflows/infra.yml` | Provisions all Azure resources (Resource Group, Key Vault, SQL Server, App Service) using Terraform |
| **Day 2 — Application** | `.github/workflows/app.yml` | Deploys the Python/Flask application code to the existing Azure Web App |

This guide assumes **you are starting completely from scratch** — no GitHub account, no Azure account, no tools installed. Follow every step in order.

---

## Table of Contents

1. [What You'll Build](#1-what-youll-build)
2. [Install Required Tools](#2-install-required-tools)
3. [Create a GitHub Account](#3-create-a-github-account)
4. [Set Up Your Azure Account](#4-set-up-your-azure-account)
5. [Log In to Azure from Your Terminal](#5-log-in-to-azure-from-your-terminal)
6. [Create a Service Principal (Pipeline Identity)](#6-create-a-service-principal-pipeline-identity)
7. [Set Up Terraform Remote State Storage](#7-set-up-terraform-remote-state-storage)
8. [Grant the Service Principal Access to the State Storage](#8-grant-the-service-principal-access-to-the-state-storage)
9. [Create Your GitHub Repository](#9-create-your-github-repository)
10. [Add Azure Secrets to GitHub](#10-add-azure-secrets-to-github)
11. [Create the Production Environment Gate](#11-create-the-production-environment-gate)
12. [Push Your Code to GitHub](#12-push-your-code-to-github)
13. [Run the Day 0 Infrastructure Pipeline](#13-run-the-day-0-infrastructure-pipeline)
14. [Run the Day 2 Application Pipeline](#14-run-the-day-2-application-pipeline)
15. [Verify Everything in Azure](#15-verify-everything-in-azure)
16. [Clean Teardown](#16-clean-teardown)

---

## 1. What You'll Build

The **Day 0 pipeline** creates the following Azure resources:

- **Resource Group** (`rg-cloud-access-demo`) — a logical container for all resources
- **Key Vault** — stores the database password as a secret
- **Azure SQL Server & Database** — the backend database
- **App Service Plan + Linux Web App** — hosts the Flask application
- **Firewall rules & access policies** — wires everything together securely

The **Day 2 pipeline** takes the Flask app in `src/` and deploys it to the Web App created by Day 0.

The Web App reads the database password from Key Vault at runtime using a native Key Vault Reference — the secret is never exposed in application config.

---

## 2. Install Required Tools

Install these on your local machine before continuing.

### Git
Git is a version control tool. You'll use it to push your code to GitHub.

1. Download from [https://git-scm.com/downloads](https://git-scm.com/downloads)
2. Run the installer — accept all defaults
3. Verify it works:
   ```bash
   git --version
   ```

### Azure CLI
The Azure CLI lets you manage Azure resources from your terminal.

1. Download from [https://learn.microsoft.com/en-us/cli/azure/install-azure-cli](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
2. Run the installer — accept all defaults
3. **Close and reopen your terminal**, then verify:
   ```bash
   az --version
   ```

### Terraform
Terraform is an infrastructure-as-code tool that creates Azure resources from `.tf` files.

1. Download from [https://developer.hashicorp.com/terraform/downloads](https://developer.hashicorp.com/terraform/downloads)
2. Extract the `terraform.exe` (or binary) to a folder on your PATH
3. Verify:
   ```bash
   terraform --version
   ```

### VS Code (recommended)
1. Download from [https://code.visualstudio.com/](https://code.visualstudio.com/)

---

## 3. Create a GitHub Account

If you already have a GitHub account, skip this step.

1. Go to [https://github.com](https://github.com)
2. Click **Sign up**
3. Enter your email, create a password, choose a username
4. Complete the verification puzzle and confirm your email
5. You're now logged in to GitHub

---

## 4. Set Up Your Azure Account

If you already have an Azure subscription, skip this step.

1. Go to [https://azure.microsoft.com/en-us/free/](https://azure.microsoft.com/en-us/free/)
2. Click **Start free** and sign in with a Microsoft account (or create one)
3. Enter your details and payment info (you won't be charged for the free tier)
4. Once created, go to [https://portal.azure.com](https://portal.azure.com)
5. In the search bar at the top, type **Subscriptions** and click on it
6. Note down your **Subscription ID** — you'll need it repeatedly. It looks like: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`

---

## 5. Log In to Azure from Your Terminal

Open PowerShell (Windows) or Terminal (Mac/Linux):

```bash
az login
```

A browser window will open. Sign in with the same Microsoft account you used for Azure. Once logged in, you'll see a list of your subscriptions in the terminal.

Set your active subscription (replace the placeholder with your real Subscription ID):

```bash
az account set --subscription="<YOUR_SUBSCRIPTION_ID>"
```

Verify you're on the right subscription:

```bash
az account show --query "{Name:name, SubscriptionId:id}" -o table
```

---

## 6. Create a Service Principal (Pipeline Identity)

GitHub Actions can't log in as *you*. It needs its own identity — called a **Service Principal** — to authenticate to Azure.

### 6a. Create the target Resource Group first

The Service Principal needs something to be scoped to. Create the resource group that Terraform will manage:

```bash
az group create --name "rg-cloud-access-demo" --location "uksouth"
```

### 6b. Create the Service Principal

```bash
az ad sp create-for-rbac --name "Demo-Pipeline-SP" --role Contributor --scopes /subscriptions/<YOUR_SUBSCRIPTION_ID>/resourceGroups/rg-cloud-access-demo
```

This outputs a JSON block like:

```json
{
  "appId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "displayName": "Demo-Pipeline-SP",
  "password": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "tenant": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

> **CRITICAL**: Copy this output and save it somewhere safe (e.g., a temporary text file). The `password` is shown only once and cannot be retrieved later. You'll need all four values in Step 10.

| JSON field | What it is | GitHub Secret name |
|---|---|---|
| `appId` | The Service Principal's client ID | `AZURE_CLIENT_ID` |
| `password` | The Service Principal's password | `AZURE_CLIENT_SECRET` |
| `tenant` | Your Azure AD tenant ID | `AZURE_TENANT_ID` |
| *(from Step 5)* | Your Subscription ID | `AZURE_SUBSCRIPTION_ID` |

---

## 7. Set Up Terraform Remote State Storage

Terraform tracks what infrastructure it has created in a **state file**. In a team/CI environment, this file must be stored centrally in Azure — never on a local machine.

### 7a. Create a resource group for state storage

```bash
az group create --name "rg-terraform-state-demo" --location "uksouth"
```

### 7b. Create a Storage Account

The name must be **globally unique** across all of Azure (lowercase letters and numbers only, 3–24 characters). If the name is taken, change the numbers at the end:

```bash
az storage account create --name "tfstatedemostorage001" --resource-group "rg-terraform-state-demo" --location "uksouth" --sku Standard_LRS
```

### 7c. Create a Blob Container inside the Storage Account

```bash
az storage container create --name "tfstate" --account-name "tfstatedemostorage001"
```

> **Important**: If you changed the storage account name above, you must also update the `storage_account_name` value in `main.tf` to match.

---

## 8. Grant the Service Principal Access to the State Storage

The Service Principal needs Contributor access to the state storage resource group too, otherwise the pipeline can't read or write the Terraform state.

First, find the Service Principal's **Object ID** (this is different from `appId`):

```bash
az ad sp list --display-name "Demo-Pipeline-SP" --query "[0].id" -o tsv
```

Then grant it access:

```bash
az role assignment create --assignee "<SP_OBJECT_ID>" --role "Contributor" --scope "/subscriptions/<YOUR_SUBSCRIPTION_ID>/resourceGroups/rg-terraform-state-demo"
```

---

## 9. Create Your GitHub Repository

### 9a. Create the repository on GitHub

1. Go to [https://github.com](https://github.com) and sign in
2. Click the **+** icon in the top-right corner, then **New repository**
3. Fill in:
   - **Repository name**: `cloud-access-demo`
   - **Visibility**: **Public** *(required for free accounts to use Environment protection rules)*
   - **Do NOT** check "Add a README file" (you already have one)
4. Click **Create repository**
5. GitHub will show you a page with setup instructions — leave this page open, you'll need the URL

### 9b. Connect your local folder to GitHub

Open your terminal and navigate to your project folder:

```bash
cd c:\windsurf\Devops\cloud-access-demo
```

Initialise Git and push to GitHub (replace `<YOUR_GITHUB_USERNAME>` with your actual username):

```bash
git init
git add .
git commit -m "initial commit"
git branch -M main
git remote add origin https://github.com/<YOUR_GITHUB_USERNAME>/cloud-access-demo.git
git push -u origin main
```

If prompted, sign in with your GitHub credentials.

---

## 10. Add Azure Secrets to GitHub

The pipelines need your Azure credentials to run. These are stored as encrypted **Secrets** in GitHub — they are never visible in logs.

1. In your GitHub repository, click **Settings** (the gear icon tab, far right)
2. In the left sidebar, click **Secrets and variables** → **Actions**
3. Click **New repository secret** and add each of the following (one at a time):

| Secret name | Value (from Step 6) |
|---|---|
| `AZURE_CLIENT_ID` | The `appId` from the Service Principal output |
| `AZURE_CLIENT_SECRET` | The `password` from the Service Principal output |
| `AZURE_TENANT_ID` | The `tenant` from the Service Principal output |
| `AZURE_SUBSCRIPTION_ID` | Your Azure Subscription ID (from Step 5) |

When you're done, you should see all four secrets listed on the Actions secrets page.

---

## 11. Create the Production Environment Gate

Both pipelines require manual approval before deploying. This is enforced through a GitHub **Environment**.

1. In your repository, go to **Settings** → **Environments**
2. Click **New environment**
3. Name it exactly: `Production` (capital P — must match the workflow files)
4. Click **Configure environment**
5. Under **Environment protection rules**, check **Required reviewers**
6. In the search box, type your own GitHub username and select it
7. Click **Save protection rules**

Now whenever either pipeline wants to deploy, it will pause and wait for you to click "Approve".

---

## 12. Push Your Code to GitHub

If you've made any changes since the initial push (e.g., updating `main.tf` with your storage account name), push them now:

```bash
git add .
git commit -m "configure pipelines and infrastructure"
git push
```

---

## 13. Run the Day 0 Infrastructure Pipeline

The Day 0 pipeline provisions all Azure resources. It triggers automatically when `.tf` files are pushed, but you can also trigger it manually.

### Automatic trigger
If you just pushed changes to `main.tf`, the pipeline is already running. Go to:

**Your repository → Actions tab**

You'll see a workflow run called **"Day 0 — Infrastructure"**. Click on it.

### Manual trigger
If the pipeline didn't trigger (e.g., you didn't change any `.tf` files):

1. Go to the **Actions** tab
2. In the left sidebar, click **Day 0 — Infrastructure**
3. Click the **Run workflow** button (top right)
4. Select the `main` branch and click **Run workflow**

### Approve the deployment
1. The workflow will show a yellow "Waiting" badge on the **Terraform Apply** job
2. Click **Review deployments**
3. Check the **Production** box
4. Click **Approve and deploy**

Wait for the green checkmark. Your Azure infrastructure is now live.

---

## 14. Run the Day 2 Application Pipeline

The Day 2 pipeline deploys the Flask app to the Web App created by Day 0.

> **You must run Day 0 first.** Day 2 expects the Web App to already exist.

### Manual trigger (first time)
Since you may have pushed all code at once, trigger this manually:

1. Go to the **Actions** tab
2. In the left sidebar, click **Day 2 — Application**
3. Click the **Run workflow** button
4. Select the `main` branch and click **Run workflow**

### Approve the deployment
Same as Day 0 — click **Review deployments**, check **Production**, and approve.

### Future runs
After the first deployment, this pipeline will run automatically whenever you push changes to files in the `src/` folder.

---

## 15. Verify Everything in Azure

1. Go to [https://portal.azure.com](https://portal.azure.com)
2. In the search bar, type `rg-cloud-access-demo` and click on the Resource Group
3. You should see these resources:
   - **Key Vault** (`kv-demo-...`)
   - **SQL Server** (`sql-demo-...`)
   - **SQL Database** (`demodb`)
   - **App Service Plan** (`asp-demo-...`)
   - **Web App** (`app-demo-...`)
4. Click on the **Web App** → **Browse** (or copy the URL from the Overview page)
5. The Flask application should load, showing a form where you can submit messages to the database

### Viewing Key Vault secrets (optional)
By default, you won't have permission to view Key Vault secrets in the portal. To grant yourself access:

1. Click on the Key Vault resource
2. Go to **Settings → Access policies**
3. Click **+ Create**
4. Under **Secret permissions**, check **Get** and **List**
5. Click **Next**, search for your own Azure account email, select it, and click **Create**
6. Now go to **Objects → Secrets** and you can view the `database-password`

---

## 16. Clean Teardown

To avoid unnecessary charges, destroy the infrastructure when you're done.

### Pre-requisite: Set your User Object ID

The `main.tf` file has a hardcoded operator Object ID for Key Vault access (needed for `terraform destroy` to work locally). Update it with your own ID:

```bash
az ad signed-in-user show --query "id" -o tsv
```

In `main.tf`, find the second `access_policy` block inside `azurerm_key_vault` and replace the Object ID with yours.

### Destroy the infrastructure

```bash
terraform init
terraform destroy -auto-approve
```

> **Do not delete** the `rg-terraform-state-demo` resource group. Leave the state storage intact so it's ready for your next deployment.

---

## Project Structure

```
cloud-access-demo/
├── .github/
│   └── workflows/
│       ├── infra.yml          # Day 0 — Infrastructure pipeline
│       └── app.yml            # Day 2 — Application pipeline
├── src/
│   ├── app.py                 # Flask application
│   └── requirements.txt       # Python dependencies (Flask, pyodbc)
├── scripts/
│   ├── register-safeguard-asset.py  # (Future use — Safeguard integration)
│   └── requirements.txt             # (Future use — pysafeguard)
├── main.tf                    # Terraform infrastructure definition
└── readme.md                  # This file
```

---

## How the Pipelines Work

### Day 0 — Infrastructure (`infra.yml`)

```
Push *.tf to main  ──→  Terraform Plan  ──→  Approval Gate  ──→  Terraform Apply
                                                                      │
                                                             Creates: Key Vault
                                                                      SQL Server
                                                                      Web App
                                                                      etc.
```

- **Triggers on**: changes to `*.tf` files, or manual dispatch
- **Pull Requests**: runs `terraform plan` to preview changes (no approval needed)
- **Push to main**: runs `terraform apply` after manual approval
- **Authentication**: uses `ARM_*` environment variables set from GitHub Secrets

### Day 2 — Application (`app.yml`)

```
Push src/* to main  ──→  Validate App  ──→  Approval Gate  ──→  Deploy to Web App
```

- **Triggers on**: changes to `src/**` files, or manual dispatch
- **Pull Requests**: installs dependencies and runs a syntax check
- **Push to main**: zips and deploys the app to Azure after manual approval
- **Authentication**: uses `az login` with the same Service Principal credentials

---

## Troubleshooting

### "Terraform init failed — storage account not found"
You either haven't created the storage account (Step 7), or the name in `main.tf` doesn't match. Check the `storage_account_name` in the `backend "azurerm"` block.

### "The client does not have authorization to perform action"
The Service Principal doesn't have Contributor access to one of the resource groups. Re-run Step 6 and Step 8.

### "Webapp not found" in Day 2 pipeline
The Day 0 pipeline hasn't been run yet (or failed). Day 2 depends on the Web App existing. Run Day 0 first.

### Pipeline is stuck on "Waiting for review"
Click on the workflow run, click **Review deployments**, check **Production**, and click **Approve and deploy**.

### "Storage account name already taken"
Storage account names are globally unique. Change the name to something unique (add random numbers) and update `main.tf` to match.