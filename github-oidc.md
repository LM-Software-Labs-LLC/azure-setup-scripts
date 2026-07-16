# GitHub OIDC → Azure Deployment Setup

Federated credentials on an Entra app registration. No client secrets stored in GitHub, tokens are short-lived and issued per workflow run.

## 1. Set variables

```bash
export APP_NAME="github-deploy"
export SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export TENANT_ID=$(az account show --query tenantId -o tsv)
export GH_ORG="your-org"
export GH_REPO="your-repo"
```

## 2. Create the Entra app registration + service principal

```bash
export APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
az ad sp create --id $APP_ID
export SP_OBJECT_ID=$(az ad sp show --id $APP_ID --query id -o tsv)
```

## 3. Add the federated credential

This is the OIDC trust. The `subject` must match exactly how your workflow runs. For deploys from the `main` branch:

```bash
az ad app federated-credential create --id $APP_ID --parameters '{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:'"$GH_ORG"'/'"$GH_REPO"':ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

Common subject variants (one credential per pattern — no wildcards):

```text
# Environment-based (if your job uses `environment: production`)
repo:ORG/REPO:environment:production

# Pull requests
repo:ORG/REPO:pull_request

# Tags
repo:ORG/REPO:ref:refs/tags/v1.0.0
```

**Gotcha:** if your job specifies `environment:`, GitHub emits the environment subject, not the branch one. A mismatched subject is the #1 cause of `AADSTS70021` errors.

## 4. Assign RBAC

Scope as tight as you can. Contributor on a resource group is typical for deploys:

```bash
az role assignment create \
  --assignee-object-id $SP_OBJECT_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/YOUR_RG"
```

If the pipeline creates role assignments itself (e.g. Bicep deploying managed identities with RBAC), you'll also need `Role Based Access Control Administrator` or `User Access Administrator`.

## 5. Add GitHub secrets

Not sensitive values, but convention is to store them as secrets. `gh secret set` targets the repo from the git remote of your cwd; use `-R org/repo` to be explicit:

```bash
gh secret set AZURE_CLIENT_ID -R "$GH_ORG/$GH_REPO" --body "$APP_ID"
gh secret set AZURE_TENANT_ID -R "$GH_ORG/$GH_REPO" --body "$TENANT_ID"
gh secret set AZURE_SUBSCRIPTION_ID -R "$GH_ORG/$GH_REPO" --body "$SUBSCRIPTION_ID"
```

## 6. Workflow

The critical part is `permissions: id-token: write` — without it the runner can't request an OIDC token and you get "Unable to get ACTIONS_ID_TOKEN_REQUEST_URL".

```yaml
name: deploy

on:
  push:
    branches: [main]

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Azure login
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Deploy
        run: |
          az deployment group create \
            --resource-group YOUR_RG \
            --template-file main.bicep
```

## 7. Verify

Push to main and watch the login step. To debug trust issues:

```bash
az ad app federated-credential list --id $APP_ID -o table
```

## Notes

- The service principal is a **deploy-time identity**, not a runtime owner. Deleting the app registration kills pipeline login but leaves deployed resources untouched.
- Resources needing runtime identity (App Service → Key Vault, etc.) should get their own managed identity — don't reuse the pipeline SP.
- Multiple environments: one federated credential per GitHub environment on the same app, RBAC scoped per resource group.
