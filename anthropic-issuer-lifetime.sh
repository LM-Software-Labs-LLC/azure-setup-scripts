#!/usr/bin/env bash
# =============================================================================
# Set an Anthropic federation ISSUER's max_jwt_lifetime_seconds (interactive)
#
# Fixes `jwt_lifetime_too_long` when a workload's Entra managed-identity token
# (~24h, not shortenable) exceeds the issuer's max allowed assertion lifetime.
# The Console wizard hides this field, so this script drives the internal Console
# API using your logged-in session cookie.
#
# It asks for each value ONE AT A TIME with instructions on where to find it,
# optionally lists your issuers so you can pick the right one, then makes the
# curl request and confirms the new value.
#
#   ⚠  The sessionKey is a FULL-ACCESS Console credential. This script never
#      stores it; sign out / rotate your session afterward.
#
# Prefer the no-secret paths first (see docs/claude-workload-identity-federation.md):
#   A) Console UI  → open the issuer → set max token lifetime
#   B) Documented API with an org-admin OAuth bearer
# Use this cookie path only when A and B are not available.
#
# Prerequisites: curl, jq.
# Usage: chmod +x scripts/set-anthropic-issuer-lifetime.sh
#        ./scripts/set-anthropic-issuer-lifetime.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}ℹ${NC}  $*"; }
success() { echo -e "${GREEN}✓${NC}  $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
error()   { echo -e "${RED}✗${NC}  $*" >&2; }
heading() { echo -e "\n${BOLD}${BLUE}── $* ──${NC}"; }
step()    { echo -e "\n${BOLD}$*${NC}"; }
prompt()  { echo -en "${BOLD}› ${NC}"; }

API="https://api.anthropic.com/api/console/organizations"

# ── Preflight ─────────────────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1 || { error "curl not found."; exit 1; }
command -v jq   >/dev/null 2>&1 || { error "jq not found. Install jq and re-run."; exit 1; }

cat <<EOF

${BOLD}Anthropic issuer token-lifetime updater${NC}
This uses your Console ${BOLD}sessionKey${NC} cookie (a full-access secret). Have a
Claude Console tab open and signed in as an org ${BOLD}admin/owner${NC} before starting.
EOF

# ── Step 1: sessionKey cookie ─────────────────────────────────────────────────
step "Step 1 of 4 — sessionKey cookie"
cat <<EOF
Where to find it:
  1. Open ${CYAN}https://platform.claude.com${NC} and sign in (org admin/owner).
  2. Open DevTools: ${BOLD}F12${NC} (or ⌥⌘I on macOS).
  3. Go to the ${BOLD}Application${NC} tab → Storage → ${BOLD}Cookies${NC} →
     ${CYAN}https://platform.claude.com${NC}.
  4. Click the ${BOLD}sessionKey${NC} row and copy its Value (starts ${BOLD}sk-ant-sid...${NC}).

Paste it below (input hidden):
EOF
prompt
read -rs SESSION_KEY
echo
[[ -z "${SESSION_KEY:-}" ]] && { error "sessionKey is required."; exit 1; }
if [[ "$SESSION_KEY" != sk-ant-sid* ]]; then
  warn "That doesn't look like a sessionKey (expected it to start with 'sk-ant-sid')."
fi
success "sessionKey captured (${#SESSION_KEY} chars, ends …${SESSION_KEY: -4})"

# ── Step 2: organization id ───────────────────────────────────────────────────
step "Step 2 of 4 — organization id"
cat <<EOF
Where to find it (same Cookies view as above):
  • Copy the value of the ${BOLD}lastActiveOrg${NC} cookie, OR
  • Take it from the Console URL after /organizations/ (a UUID).
EOF
prompt
read -r ORG_ID
[[ -z "${ORG_ID:-}" ]] && { error "organization id is required."; exit 1; }
success "organization id: ${ORG_ID}"

COOKIE="sessionKey=${SESSION_KEY}; lastActiveOrg=${ORG_ID}"
HDRS=(-H "Cookie: ${COOKIE}"
      -H "anthropic-client-platform: web_claude_ai"
      -H "Origin: https://platform.claude.com"
      -H "content-type: application/json")

# ── Step 3: issuer id (list to help pick) ─────────────────────────────────────
step "Step 3 of 4 — federation issuer id (fdis_...)"
info "Fetching your issuers so you can pick the right one..."
LIST_RESP="$(curl -sS "${API}/${ORG_ID}/federation_issuers?include_archived=false" "${HDRS[@]}" || true)"

if echo "$LIST_RESP" | jq -e '.data | type == "array"' >/dev/null 2>&1; then
  echo ""
  echo -e "  ${BOLD}#  fdis id                              issuer                                  max_jwt_lifetime${NC}"
  echo "$LIST_RESP" | jq -r '.data | to_entries[] |
    "  \(.key+1)  \(.value.id)  \(.value.issuer_url // .value.issuer // "?")  \(.value.max_jwt_lifetime_seconds // "?")"'
  echo ""
  info "Pick the ${BOLD}v1${NC} issuer (https://sts.windows.net/<tenant>/) your rule uses."
  echo "Enter the row # from the list, or paste an fdis_ id directly:"
  prompt
  read -r PICK
  if [[ "$PICK" =~ ^[0-9]+$ ]]; then
    FDIS_ID="$(echo "$LIST_RESP" | jq -r --argjson i "$((PICK-1))" '.data[$i].id // empty')"
  else
    FDIS_ID="$PICK"
  fi
else
  warn "Could not list issuers (response below). You can still enter the id manually."
  echo "$LIST_RESP" | head -c 400; echo
  echo "Enter the federation issuer id (fdis_...):"
  prompt
  read -r FDIS_ID
fi
[[ -z "${FDIS_ID:-}" ]] && { error "issuer id is required."; exit 1; }
[[ "$FDIS_ID" != fdis_* ]] && warn "That doesn't look like an fdis_ id."
success "issuer: ${FDIS_ID}"

# ── Step 4: new lifetime ──────────────────────────────────────────────────────
step "Step 4 of 4 — new max_jwt_lifetime_seconds"
cat <<EOF
Azure managed-identity tokens run ~86,700s (~24h) and cannot be shortened, so
this must exceed that. Recommended: ${BOLD}100800${NC} (28h). Range: 1–176400.
(A flat 86400 is typically ~300s too short.)
EOF
prompt
read -r LIFETIME
LIFETIME="${LIFETIME:-100800}"
if ! [[ "$LIFETIME" =~ ^[0-9]+$ ]]; then error "Lifetime must be a number."; exit 1; fi
if (( LIFETIME < 1 || LIFETIME > 176400 )); then error "Lifetime must be 1–176400."; exit 1; fi

# ── Confirm + submit ──────────────────────────────────────────────────────────
heading "Review"
echo -e "  Organization: ${BOLD}${ORG_ID}${NC}"
echo -e "  Issuer:       ${BOLD}${FDIS_ID}${NC}"
echo -e "  New lifetime: ${BOLD}${LIFETIME}${NC} seconds"
echo ""
echo -en "${BOLD}Send the update now? [y/N]: ${NC}"
read -r CONFIRM
CONFIRM_LC="$(printf '%s' "$CONFIRM" | tr '[:upper:]' '[:lower:]')"
[[ "$CONFIRM_LC" != "y" && "$CONFIRM_LC" != "yes" ]] && { warn "Aborted — nothing changed."; exit 0; }

heading "Updating issuer"
HTTP_BODY="$(curl -sS -w $'\n%{http_code}' -X POST "${API}/${ORG_ID}/federation_issuers/${FDIS_ID}" \
  "${HDRS[@]}" -d "{\"max_jwt_lifetime_seconds\":${LIFETIME}}")"
HTTP_CODE="$(printf '%s' "$HTTP_BODY" | tail -n1)"
BODY="$(printf '%s' "$HTTP_BODY" | sed '$d')"

ECHOED="$(echo "$BODY" | jq -r '.max_jwt_lifetime_seconds // empty' 2>/dev/null || true)"
if [[ "$HTTP_CODE" == "200" && "$ECHOED" == "$LIFETIME" ]]; then
  success "Done — issuer ${FDIS_ID} max_jwt_lifetime_seconds is now ${ECHOED}."
else
  error "Update did not confirm (HTTP ${HTTP_CODE}). Response:"
  echo "$BODY" | jq . 2>/dev/null || echo "$BODY"
  echo ""
  warn "If unauthorized, ensure the sessionKey is fresh and from an org admin/owner."
fi

echo ""
warn "Security: the sessionKey grants full Console access. Sign out / rotate it now."
