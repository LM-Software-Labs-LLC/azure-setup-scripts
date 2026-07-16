#!/usr/bin/env bash
# =============================================================================
# Anthropic Workload Identity Federation (WIF) — client-agnostic setup tool
#
# Keyless Anthropic auth for any client deployment on Azure: a workload's
# managed identity mints an Entra token that Anthropic exchanges for a
# short-lived `sk-ant-oat...` token. No ANTHROPIC_API_KEY to store or rotate.
#
# This tool automates every part of the flow that HAS an API, and prints the
# one-time Console steps for the parts that do not. It is fully parameterised —
# nothing about a specific client is hardcoded.
#
#   Phase 1  Azure identity   create/reuse a user-assigned managed identity
#   Phase 2  Entra app        create/reuse the app registration used as the 'aud'
#   Phase 3  Console values   print the exact WIF wizard inputs
#   Phase 4  Issuer lifetime  points at scripts/set-anthropic-issuer-lifetime.sh
#   Phase 5  Verify container (optional) deploy a small re-runnable Container
#                             Apps Job that performs the mint+exchange in-cluster
#   Phase 6  Output           emit the deploy.env block + a summary
#
# The only thing this cannot do is CREATE the Anthropic issuer/service-account/
# rule — those are made once in the Console wizard (no public create API). Run
# phases 1-3, complete the wizard, set the issuer lifetime
# (scripts/set-anthropic-issuer-lifetime.sh), then re-run with the returned ids
# for the verify container. Full background: docs/claude-workload-identity-federation.md
#
# Prerequisites: az CLI (logged in), jq. The containerapp extension is installed
# automatically if the verify container is requested.
#
# Usage (interactive):
#   chmod +x scripts/setup-anthropic-wif.sh
#   ./scripts/setup-anthropic-wif.sh
#
# Usage (non-interactive, e.g. per-client CI):
#   NAME_PREFIX=acme RG=acme-rg LOCATION=eastus2 \
#     ./scripts/setup-anthropic-wif.sh
#
# All inputs may be supplied as env vars to skip prompts:
#   SUBSCRIPTION           az subscription id to target
#   NAME_PREFIX            drives resource names (<prefix>-wif-id, <prefix>-wif-* )
#   RG                     resource group (created if missing)
#   LOCATION               azure region (e.g. eastus2)
#   MI_NAME                managed identity name        (default <prefix>-wif-id)
#   MI_RESOURCE_ID         reuse an existing UAMI by full resource id (skips create)
#   AUDIENCE_APP_ID        reuse an app registration as the audience (skips create)
#   AUDIENCE_APP_NAME      display name when creating one (default "<prefix> WIF Audience")
#   ORG_ID                 Anthropic organization id              } needed for the
#   FDRL_ID                federation rule id (fdrl_...)          } verify container
#   SVAC_ID                service account id (svac_...)          }
#   WRKSPC_ID              workspace id (wrkspc_...) — only if the rule spans workspaces
#   CREATE_CONTAINER       "true" to deploy the verify container non-interactively
#   CHECK_IMAGE            container image for the checker (default curlimages/curl:8.11.0)
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}ℹ${NC}  $*"; }
success() { echo -e "${GREEN}✓${NC}  $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
error()   { echo -e "${RED}✗${NC}  $*" >&2; }
heading() { echo -e "\n${BOLD}${BLUE}── $* ──${NC}"; }
prompt()  { echo -en "${BOLD}$*${NC} "; }
ask() { # ask VAR "Question" ["default"]
  local __var="$1" __q="$2" __def="${3:-}" __ans
  if [[ -n "${!__var:-}" ]]; then return 0; fi
  if [[ -n "$__def" ]]; then prompt "$__q [$__def]:"; else prompt "$__q:"; fi
  read -r __ans
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

# ── Defaults ──────────────────────────────────────────────────────────────────
CHECK_IMAGE="${CHECK_IMAGE:-curlimages/curl:8.11.0}"
OAUTH_SCOPE="workspace:developer"

# ── Preflight ─────────────────────────────────────────────────────────────────
heading "Preflight"
command -v az >/dev/null 2>&1 || { error "Azure CLI not found. https://aka.ms/azcli"; exit 1; }
command -v jq >/dev/null 2>&1 || { error "jq not found. Install jq and re-run."; exit 1; }
if ! az account show >/dev/null 2>&1; then
  warn "Not logged in. Running az login..."
  az login >/dev/null
fi
[[ -n "${SUBSCRIPTION:-}" ]] && az account set --subscription "$SUBSCRIPTION"
TENANT_ID="$(az account show --query tenantId -o tsv)"
SUB_NAME="$(az account show --query name -o tsv)"
success "Azure CLI ready — subscription: ${BOLD}${SUB_NAME}${NC}"
info    "Tenant: ${BOLD}${TENANT_ID}${NC}"
# A managed identity ONLY ever emits a v1 token. Never use the v2 issuer.
ISSUER_URL="https://sts.windows.net/${TENANT_ID}/"

# ── Inputs ────────────────────────────────────────────────────────────────────
heading "Deployment inputs"
ask NAME_PREFIX "Client name prefix for resources (e.g. acme)"
[[ -z "${NAME_PREFIX:-}" ]] && { error "NAME_PREFIX is required."; exit 1; }
ask RG "Resource group" "${NAME_PREFIX}-rg"
ask LOCATION "Azure region" "eastus2"

if [[ "$(az group exists -n "$RG")" != "true" ]]; then
  info "Creating resource group ${BOLD}${RG}${NC} in ${LOCATION}..."
  az group create -n "$RG" -l "$LOCATION" -o none
  success "Resource group created"
else
  success "Using existing resource group ${RG}"
fi

# ── Phase 1: user-assigned managed identity (the token SUBJECT) ───────────────
heading "Phase 1 — managed identity (token subject)"
MI_NAME="${MI_NAME:-${NAME_PREFIX}-wif-id}"

if [[ -n "${MI_RESOURCE_ID:-}" ]]; then
  MI_JSON="$(az identity show --ids "$MI_RESOURCE_ID" --query '{clientId:clientId, principalId:principalId, id:id, name:name}' -o json)"
elif az identity show -g "$RG" -n "$MI_NAME" >/dev/null 2>&1; then
  info "Reusing managed identity ${BOLD}${MI_NAME}${NC}"
  MI_JSON="$(az identity show -g "$RG" -n "$MI_NAME" --query '{clientId:clientId, principalId:principalId, id:id, name:name}' -o json)"
else
  info "Creating user-assigned managed identity ${BOLD}${MI_NAME}${NC}..."
  MI_JSON="$(az identity create -g "$RG" -n "$MI_NAME" -l "$LOCATION" --query '{clientId:clientId, principalId:principalId, id:id, name:name}' -o json)"
  success "Managed identity created"
fi
MI_CLIENT_ID="$(echo "$MI_JSON" | jq -r '.clientId')"
MI_OBJECT_ID="$(echo "$MI_JSON" | jq -r '.principalId')"
MI_RESOURCE_ID="$(echo "$MI_JSON" | jq -r '.id')"
MI_NAME="$(echo "$MI_JSON" | jq -r '.name')"
success "Identity: ${BOLD}${MI_NAME}${NC}"
info    "Object (principal) id → rule SUBJECT: ${BOLD}${MI_OBJECT_ID}${NC}"
info    "Client id → IMDS client_id:          ${BOLD}${MI_CLIENT_ID}${NC}"
warn    "Assign this identity to whatever workload calls Anthropic (app + worker):"
echo    "    az containerapp update -n <app> -g $RG --user-assigned $MI_RESOURCE_ID"

# ── Phase 2: audience app registration (the token 'aud') ──────────────────────
heading "Phase 2 — audience Entra application"
if [[ -z "${AUDIENCE_APP_ID:-}" ]]; then
  info "The audience is any Entra app registration used only as the token 'aud'."
  info "Reuse an existing registration (e.g. the app's SSO one) or create a dedicated one."
  ask AUDIENCE_APP_ID "Existing App (client) ID to use as audience, or Enter to create one" ""
fi

if [[ -z "${AUDIENCE_APP_ID:-}" ]]; then
  AUDIENCE_APP_NAME="${AUDIENCE_APP_NAME:-${NAME_PREFIX} WIF Audience}"
  info "Creating app registration '${AUDIENCE_APP_NAME}'..."
  AUDIENCE_APP_ID="$(az ad app create --display-name "$AUDIENCE_APP_NAME" --sign-in-audience "AzureADMyOrg" --query appId -o tsv)"
  success "Created audience app: ${AUDIENCE_APP_ID}"
else
  APP_DISPLAY="$(az ad app show --id "$AUDIENCE_APP_ID" --query displayName -o tsv 2>/dev/null || true)"
  [[ -z "$APP_DISPLAY" ]] && { error "App registration ${AUDIENCE_APP_ID} not found."; exit 1; }
  success "Using audience app: ${APP_DISPLAY} (${AUDIENCE_APP_ID})"
fi
AUDIENCE_URI="api://${AUDIENCE_APP_ID}"

EXISTING_URIS="$(az ad app show --id "$AUDIENCE_APP_ID" --query "identifierUris" -o json 2>/dev/null || echo '[]')"
if echo "$EXISTING_URIS" | jq -e --arg u "$AUDIENCE_URI" 'index($u)' >/dev/null 2>&1; then
  success "Identifier URI already set: ${AUDIENCE_URI}"
else
  MERGED_URIS="$(echo "$EXISTING_URIS" | jq -c --arg u "$AUDIENCE_URI" '. + [$u] | unique')"
  # shellcheck disable=SC2046
  if az ad app update --id "$AUDIENCE_APP_ID" --identifier-uris $(echo "$MERGED_URIS" | jq -r '.[]') >/dev/null 2>&1; then
    success "Identifier URI set: ${AUDIENCE_URI}"
  else
    warn "Could not set identifier URI automatically — add ${AUDIENCE_URI} in the portal (Expose an API)."
  fi
fi

# ── Phase 3: Anthropic Console wizard values ──────────────────────────────────
heading "Phase 3 — Anthropic Console (Connect workload → Microsoft Entra)"
cat <<EOF
Settings → Workload Identity → Connect workload → Microsoft Entra, then enter:

  Issuer (v1 — a managed identity NEVER emits v2):
    ${BOLD}${ISSUER_URL}${NC}
  Object (principal) ID  →  rule SUBJECT (the managed identity, NOT the app SP):
    ${BOLD}${MI_OBJECT_ID}${NC}
  Application (client) ID  →  expected AUDIENCE:
    ${BOLD}${AUDIENCE_APP_ID}${NC}   (resource: ${AUDIENCE_URI})
  OAuth scope:
    ${BOLD}${OAUTH_SCOPE}${NC}

The wizard returns an issuer (fdis_...), service account (svac_...) and rule
(fdrl_...). Copy them — then set the issuer lifetime with
scripts/set-anthropic-issuer-lifetime.sh, and re-run this tool with
FDRL_ID / SVAC_ID / ORG_ID (and WRKSPC_ID if applicable) for the verify container.
EOF

# ── Phase 4: issuer token-lifetime cap (handled by a dedicated script) ────────
heading "Phase 4 — issuer token-lifetime cap (fixes jwt_lifetime_too_long)"
info "Azure MI tokens live ~86,700s (~24h) and CANNOT be shortened, and the wizard"
info "sets the ISSUER max_jwt_lifetime_seconds to 3600 and hides it. Raise it above"
info "the token lifetime (recommended 100800) or the exchange fails."
info "Run the dedicated helper for this step:"
echo  "    scripts/set-anthropic-issuer-lifetime.sh"
info "(or set it in the Console UI: Settings → Workload Identity → open the issuer)."

# ── Phase 5: verify container (small re-runnable Container Apps Job) ───────────
heading "Phase 5 — verification container"
info "Deploys a small Container Apps Job carrying the managed identity that mints"
info "the Entra token and exchanges it at Anthropic — the same IDENTITY_ENDPOINT"
info "path production uses. Re-run it anytime with: az containerapp job start ..."

DO_CONTAINER="${CREATE_CONTAINER:-}"
if [[ -z "$DO_CONTAINER" ]]; then
  prompt "Deploy the verification container now? [y/N]:"; read -r DO_CONTAINER
fi

if [[ "${DO_CONTAINER,,}" == "true" || "${DO_CONTAINER,,}" == "y" || "${DO_CONTAINER,,}" == "yes" ]]; then
  ask FDRL_ID "Federation rule id (fdrl_...)"
  ask ORG_ID  "Anthropic organization id"
  ask SVAC_ID "Service account id (svac_...)"
  ask WRKSPC_ID "Workspace id (wrkspc_..., blank if none)" ""
  if [[ -z "${FDRL_ID:-}" || -z "${ORG_ID:-}" || -z "${SVAC_ID:-}" ]]; then
    error "FDRL_ID, ORG_ID and SVAC_ID are required to run the verification exchange."
    exit 1
  fi

  info "Ensuring the containerapp CLI extension is present..."
  az config set extension.use_dynamic_install=yes_without_prompt -o none 2>/dev/null || true
  az extension add --name containerapp --upgrade -y -o none 2>/dev/null || true

  ENV_NAME="${NAME_PREFIX}-wif-env"
  JOB_NAME="${NAME_PREFIX}-wif-check"

  if ! az containerapp env show -n "$ENV_NAME" -g "$RG" >/dev/null 2>&1; then
    info "Creating Container Apps environment ${BOLD}${ENV_NAME}${NC} (~2 min)..."
    az containerapp env create -n "$ENV_NAME" -g "$RG" -l "$LOCATION" -o none
    success "Environment created"
  else
    success "Using existing environment ${ENV_NAME}"
  fi

  # The in-container check: mint via IDENTITY_ENDPOINT (Container Apps) with an
  # IMDS fallback, decode the assertion, then exchange at Anthropic. Base64-encoded
  # so it survives being passed through `az ... --args` without quoting hazards.
  read -r -d '' CHECK_SRC <<'CHECK' || true
set -u
echo "[wif-check] resource=$AUDIENCE client_id=${MI_CLIENT_ID:-<system>}"
EP="${IDENTITY_ENDPOINT:-http://169.254.169.254/metadata/identity/oauth2/token}"
if [ -n "${IDENTITY_HEADER:-}" ]; then
  RESP=$(curl -s "$EP?resource=$AUDIENCE&api-version=2019-08-01${MI_CLIENT_ID:+&client_id=$MI_CLIENT_ID}" -H "X-IDENTITY-HEADER: $IDENTITY_HEADER")
else
  RESP=$(curl -s "$EP?resource=$AUDIENCE&api-version=2018-02-01${MI_CLIENT_ID:+&client_id=$MI_CLIENT_ID}" -H "Metadata: true")
fi
JWT=$(printf '%s' "$RESP" | sed 's/.*"access_token":"//; s/".*//')
if [ -z "$JWT" ] || [ "$JWT" = "$RESP" ]; then
  echo "[wif-check] FAILED to mint Entra token:"; echo "$RESP"; exit 1
fi
echo "[wif-check] minted Entra assertion (len=${#JWT})"
P=$(printf '%s' "$JWT" | cut -d. -f2); M=$(( ${#P} % 4 ))
[ "$M" -ne 0 ] && P="$P$(printf '%*s' $((4-M)) '' | tr ' ' '=')"
echo "[wif-check] assertion payload:"; printf '%s' "$P" | tr '_-' '/+' | base64 -d 2>/dev/null || true; echo
BODY="{\"grant_type\":\"urn:ietf:params:oauth:grant-type:jwt-bearer\",\"assertion\":\"$JWT\",\"federation_rule_id\":\"$FDRL\",\"organization_id\":\"$ORG\",\"service_account_id\":\"$SVAC\""
[ -n "${WRKSPC:-}" ] && BODY="$BODY,\"workspace_id\":\"$WRKSPC\""
BODY="$BODY}"
OUT=$(curl -sS https://api.anthropic.com/v1/oauth/token -H "content-type: application/json" -d "$BODY")
echo "[wif-check] exchange response: $OUT"
if echo "$OUT" | grep -q "sk-ant-oat"; then echo "[wif-check] PASS"; exit 0; else echo "[wif-check] FAIL (see Console → Authentication events for the reason)"; exit 1; fi
CHECK
  CHECK_B64="$(printf '%s' "$CHECK_SRC" | base64 | tr -d '\n')"
  RUN_CMD="echo ${CHECK_B64} | base64 -d | sh"

  if az containerapp job show -n "$JOB_NAME" -g "$RG" >/dev/null 2>&1; then
    info "Updating existing job ${BOLD}${JOB_NAME}${NC}..."
    az containerapp job update -n "$JOB_NAME" -g "$RG" \
      --image "$CHECK_IMAGE" \
      --command "/bin/sh" --args "-c" "$RUN_CMD" \
      --set-env-vars "AUDIENCE=$AUDIENCE_URI" "MI_CLIENT_ID=$MI_CLIENT_ID" "FDRL=$FDRL_ID" "ORG=$ORG_ID" "SVAC=$SVAC_ID" "WRKSPC=${WRKSPC_ID:-}" \
      -o none
  else
    info "Creating verification job ${BOLD}${JOB_NAME}${NC}..."
    az containerapp job create -n "$JOB_NAME" -g "$RG" --environment "$ENV_NAME" \
      --trigger-type Manual --replica-timeout 300 --replica-retry-limit 0 --parallelism 1 \
      --mi-user-assigned "$MI_RESOURCE_ID" \
      --image "$CHECK_IMAGE" --cpu 0.25 --memory 0.5Gi \
      --command "/bin/sh" --args "-c" "$RUN_CMD" \
      --env-vars "AUDIENCE=$AUDIENCE_URI" "MI_CLIENT_ID=$MI_CLIENT_ID" "FDRL=$FDRL_ID" "ORG=$ORG_ID" "SVAC=$SVAC_ID" "WRKSPC=${WRKSPC_ID:-}" \
      -o none
  fi
  success "Verification job ready"

  info "Starting a run..."
  az containerapp job start -n "$JOB_NAME" -g "$RG" -o none
  info "Waiting for the run to finish..."
  STATUS=""
  for _ in $(seq 1 30); do
    sleep 8
    STATUS="$(az containerapp job execution list -n "$JOB_NAME" -g "$RG" --query "[0].properties.status" -o tsv 2>/dev/null || true)"
    [[ "$STATUS" == "Succeeded" || "$STATUS" == "Failed" ]] && break
    info "  status: ${STATUS:-Provisioning}..."
  done
  EXEC="$(az containerapp job execution list -n "$JOB_NAME" -g "$RG" --query "[0].name" -o tsv 2>/dev/null || true)"
  if [[ "$STATUS" == "Succeeded" ]]; then
    success "WIF exchange PASSED (job execution succeeded)"
  else
    warn "Job execution status: ${STATUS:-unknown}. Check the logs for the reason."
  fi
  echo ""
  info "View the exchange output (Log Analytics ingestion can lag ~1-2 min):"
  echo "    az containerapp job logs show -n $JOB_NAME -g $RG --container $JOB_NAME --execution ${EXEC:-<exec>} --follow false"
  info "Re-run the check anytime:  az containerapp job start -n $JOB_NAME -g $RG"
  info "Tear down the checker:     az containerapp job delete -n $JOB_NAME -g $RG --yes && az containerapp env delete -n $ENV_NAME -g $RG --yes"
else
  info "Skipped. Deploy it later by re-running with CREATE_CONTAINER=true plus"
  info "FDRL_ID / ORG_ID / SVAC_ID (and WRKSPC_ID if the rule spans workspaces)."
fi

# ── Phase 6: config + summary ─────────────────────────────────────────────────
heading "Phase 6 — config for deploy.env"
cat <<EOF
# ── Direct Anthropic via Workload Identity Federation ─────────────────────────
ANTHROPIC_WIF_AUDIENCE=${AUDIENCE_URI}
ANTHROPIC_WIF_CLIENT_ID=${MI_CLIENT_ID}
ANTHROPIC_FEDERATION_RULE_ID=${FDRL_ID:-}      # fdrl_... (from the Console wizard)
ANTHROPIC_ORGANIZATION_ID=${ORG_ID:-}          # Anthropic org id
ANTHROPIC_SERVICE_ACCOUNT_ID=${SVAC_ID:-}      # svac_... (from the Console wizard)
ANTHROPIC_WORKSPACE_ID=${WRKSPC_ID:-}          # wrkspc_... (only if the rule spans workspaces)
# Do NOT set ANTHROPIC_API_KEY — unused by this path.
EOF

heading "Summary"
echo -e "  Tenant:           ${BOLD}${TENANT_ID}${NC}"
echo -e "  Issuer (v1):      ${BOLD}${ISSUER_URL}${NC}"
echo -e "  Managed identity: ${BOLD}${MI_NAME}${NC}"
echo -e "  MI object id:     ${BOLD}${MI_OBJECT_ID}${NC}  (rule subject)"
echo -e "  MI client id:     ${BOLD}${MI_CLIENT_ID}${NC}"
echo -e "  MI resource id:   ${BOLD}${MI_RESOURCE_ID}${NC}"
echo -e "  Audience:         ${BOLD}${AUDIENCE_URI}${NC}"
echo ""
success "Azure side done. Complete the Console wizard (if not already), set the issuer"
info    "lifetime (scripts/set-anthropic-issuer-lifetime.sh), then wire deploy.env."
info    "Full runbook: docs/claude-workload-identity-federation.md"
