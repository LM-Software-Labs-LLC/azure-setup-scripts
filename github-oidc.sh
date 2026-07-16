#!/usr/bin/env bash
set -euo pipefail

# GitHub OIDC -> Azure setup
# Creates an Entra app + SP, federated credential, RBAC assignment,
# and pushes the three IDs to GitHub repo secrets.
# Requires: az (logged in), gh (authenticated)

# ---------- checks ----------
command -v az >/dev/null || { echo "az cli not found"; exit 1; }
command -v gh >/dev/null || { echo "gh cli not found"; exit 1; }
az account show >/dev/null 2>&1 || { echo "Not logged into az. Run: az login"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged into gh. Run: gh auth login"; exit 1; }

# ---------- inputs ----------
DEFAULT_SUB=$(az account show --query id -o tsv)
DEFAULT_TENANT=$(az account show --query tenantId -o tsv)

read -rp "App registration name [github-deploy]: " APP_NAME
APP_NAME=${APP_NAME:-github-deploy}

read -rp "Subscription ID [$DEFAULT_SUB]: " SUBSCRIPTION_ID
SUBSCRIPTION_ID=${SUBSCRIPTION_ID:-$DEFAULT_SUB}

read -rp "GitHub org/user: " GH_ORG
[[ -n "$GH_ORG" ]] || { echo "Required."; exit 1; }

read -rp "GitHub repo name: " GH_REPO
[[ -n "$GH_REPO" ]] || { echo "Required."; exit 1; }

read -rp "Resource group to grant Contributor on: " RG_NAME
[[ -n "$RG_NAME" ]] || { echo "Required."; exit 1; }

echo ""
echo "Trust type:"
echo "  1) branch (e.g. main)"
echo "  2) environment (e.g. production)"
echo "  3) pull_request"
read -rp "Choose [1]: " TRUST_TYPE
TRUST_TYPE=${TRUST_TYPE:-1}

case "$TRUST_TYPE" in
  1)
    read -rp "Branch name [main]: " BRANCH
    BRANCH=${BRANCH:-main}
    SUBJECT="repo:${GH_ORG}/${GH_REPO}:ref:refs/heads/${BRANCH}"
    CRED_NAME="github-${BRANCH}"
    ;;
  2)
    read -rp "Environment name [production]: " ENV_NAME
    ENV_NAME=${ENV_NAME:-production}
    SUBJECT="repo:${GH_ORG}/${GH_REPO}:environment:${ENV_NAME}"
    CRED_NAME="github-env-${ENV_NAME}"
    ;;
  3)
    SUBJECT="repo:${GH_ORG}/${GH_REPO}:pull_request"
    CRED_NAME="github-pr"
    ;;
  *)
    echo "Invalid choice."; exit 1
    ;;
esac

TENANT_ID=$DEFAULT_TENANT
SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}"

echo ""
echo "---------------------------------------------"
echo "App name:      $APP_NAME"
echo "Subscription:  $SUBSCRIPTION_ID"
echo "Tenant:        $TENANT_ID"
echo "Repo:          $GH_ORG/$GH_REPO"
echo "OIDC subject:  $SUBJECT"
echo "RBAC scope:    $SCOPE (Contributor)"
echo "---------------------------------------------"
read -rp "Proceed? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---------- app + sp (idempotent) ----------
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)
if [[ -z "$APP_ID" ]]; then
  echo "Creating app registration..."
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
else
  echo "App '$APP_NAME' already exists ($APP_ID), reusing."
fi

SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)
if [[ -z "$SP_OBJECT_ID" ]]; then
  echo "Creating service principal..."
  az ad sp create --id "$APP_ID" >/dev/null
  SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
else
  echo "Service principal already exists, reusing."
fi

# ---------- federated credential (idempotent) ----------
EXISTING_CRED=$(az ad app federated-credential list --id "$APP_ID" \
  --query "[?subject=='$SUBJECT'].name" -o tsv)
if [[ -z "$EXISTING_CRED" ]]; then
  echo "Creating federated credential..."
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"$CRED_NAME\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$SUBJECT\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" >/dev/null
else
  echo "Federated credential for this subject already exists, skipping."
fi

# ---------- rbac ----------
echo "Assigning Contributor on $RG_NAME..."
az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "$SCOPE" >/dev/null 2>&1 || echo "Role assignment already exists, skipping."

# ---------- github secrets ----------
echo "Setting GitHub secrets on $GH_ORG/$GH_REPO..."
gh secret set AZURE_CLIENT_ID       -R "$GH_ORG/$GH_REPO" --body "$APP_ID"
gh secret set AZURE_TENANT_ID       -R "$GH_ORG/$GH_REPO" --body "$TENANT_ID"
gh secret set AZURE_SUBSCRIPTION_ID -R "$GH_ORG/$GH_REPO" --body "$SUBSCRIPTION_ID"

echo ""
echo "Done."
echo "  Client ID:  $APP_ID"
echo "  Tenant ID:  $TENANT_ID"
echo "  Subject:    $SUBJECT"
echo ""
echo "Add 'permissions: id-token: write' to your workflow and use azure/login@v2."
