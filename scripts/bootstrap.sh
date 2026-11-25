#!/usr/bin/env bash
#
# Bootstrap the SGNL login flow into a Salesforce org.
#
# Prompts for the Falcon cloud and OAuth client credentials, deploys all
# metadata (with the cloud's hosts patched into a temporary copy of the
# project), sets the client id/secret on the External Credential principal,
# grants the chosen profile the access the flow needs, runs Test Connection,
# and, if it passes and the operator agrees, attaches the Login Flow to the
# profile.
#
# Requirements:
#   - `sf` CLI installed (npm install --global @salesforce/cli)
#   - The target org already authenticated (`sf org login web --alias <name>`)
#   - `jq` installed
#
# Usage:
#   ./scripts/bootstrap.sh
#

set -euo pipefail

# Everything this script writes (staged project, credential JSON) is private.
umask 077

# -----------------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

API_VERSION="67.0"
EXTERNAL_CREDENTIAL="NGIS_SGNL_Falcon_OAuth"
PRINCIPAL_NAME="NGIS_SGNL_Principal"
ADMIN_PERMSET="NGIS_SGNL_Login_Flow_Admin"
LOGIN_FLOW_PAGE="LoginFlowPermSets"
LOGIN_FLOW_CLASSES=(LoginFlowConfig LoginFlowController SgnlClient)
# Same allowlist as ngis-sgnl-policy-action: access.crowdstrike.com or access.<cloud>.crowdstrike.com
ACCESS_HOST_PATTERN='^access\.([a-z0-9-]+\.)*crowdstrike\.(com|red|black)$'

# ANSI helpers, plain enough to work in any terminal.
c_bold=$'\033[1m'
c_dim=$'\033[2m'
c_red=$'\033[31m'
c_green=$'\033[32m'
c_yellow=$'\033[33m'
c_cyan=$'\033[36m'
c_reset=$'\033[0m'

heading() { printf '\n%s━━━ %s ━━━%s\n' "$c_bold" "$1" "$c_reset"; }
info()    { printf '%s→%s %s\n' "$c_cyan" "$c_reset" "$1"; }
ok()      { printf '%s✔%s %s\n' "$c_green" "$c_reset" "$1"; }
warn()    { printf '%s!%s %s\n' "$c_yellow" "$c_reset" "$1"; }
fail()    { printf '%s✘%s %s\n' "$c_red" "$c_reset" "$1" >&2; }
prompt()  { printf '%s?%s %s' "$c_bold" "$c_reset" "$1"; }

die() { fail "$1"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# Escape single quotes for SOQL/Apex string literals.
soql_escape() { printf '%s' "$1" | sed "s/'/\\\\'/g"; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
require_cmd sf
require_cmd jq

heading "SGNL Login Flow: Tenant Bootstrap"
cat <<EOF
This deploys the login flow into a Salesforce org and configures it
end-to-end. You'll need a Falcon API client (client id + secret) with the
sgnl-access:read scope, mapped to your SGNL provider.
EOF

# -----------------------------------------------------------------------------
# Prompts
# -----------------------------------------------------------------------------
heading "Target org"

IDENTITY_JSON=""
while [[ -z "$IDENTITY_JSON" ]]; do
  prompt "Salesforce CLI org alias: "
  read -r ORG_ALIAS
  if [[ -z "$ORG_ALIAS" ]]; then
    fail "Org alias is required."
    continue
  fi
  info "Checking authentication for '$ORG_ALIAS'..."
  IDENTITY_JSON="$(sf org display user --target-org "$ORG_ALIAS" --json 2>/dev/null)" \
    || { IDENTITY_JSON=""; fail "Not authenticated as '$ORG_ALIAS'. Check the alias with 'sf org list', or log in with: sf org login web --alias $ORG_ALIAS"; }
done
RUNNING_USER_ID="$(echo "$IDENTITY_JSON" | jq -r '.result.id')"
RUNNING_USER_NAME="$(echo "$IDENTITY_JSON" | jq -r '.result.username')"
ok "Authenticated as $RUNNING_USER_NAME"
# The operator's own profile is refused below, so the script can't attach the
# flow where it could lock them out.
RUNNING_PROFILE_ID="$(sf data query --target-org "$ORG_ALIAS" \
  --query "SELECT ProfileId FROM User WHERE Id = '$RUNNING_USER_ID'" \
  --json 2>/dev/null | jq -r '.result.records[0].ProfileId // empty' || true)"

heading "Falcon cloud and OAuth client"

cat <<EOF
  1) US-1   access.crowdstrike.com
  2) US-2   access.us-2.crowdstrike.com
  3) EU-1   access.eu-1.crowdstrike.com
  4) Other  enter an access host
EOF
# Invalid answers ask again rather than exiting.
ACCESS_HOST=""
while [[ -z "$ACCESS_HOST" ]]; do
  prompt "Falcon cloud [1]: "
  read -r CLOUD_CHOICE
  case "${CLOUD_CHOICE:-1}" in
    1) ACCESS_HOST="access.crowdstrike.com" ;;
    2) ACCESS_HOST="access.us-2.crowdstrike.com" ;;
    3) ACCESS_HOST="access.eu-1.crowdstrike.com" ;;
    4)
      prompt "Access host (e.g. access.<cloud>.crowdstrike.com): "
      read -r ACCESS_HOST
      ACCESS_HOST="${ACCESS_HOST#https://}"
      ACCESS_HOST="${ACCESS_HOST%/}"
      ACCESS_HOST="$(printf '%s' "$ACCESS_HOST" | tr '[:upper:]' '[:lower:]')"
      if [[ ! "$ACCESS_HOST" =~ $ACCESS_HOST_PATTERN ]]; then
        fail "Invalid access host '$ACCESS_HOST'. Expected access.crowdstrike.com or access.<cloud>.crowdstrike.com."
        ACCESS_HOST=""
      fi
      ;;
    *) fail "Invalid choice '$CLOUD_CHOICE'. Enter 1, 2, 3 or 4." ;;
  esac
done
TOKEN_HOST="api.${ACCESS_HOST#access.}"
info "API endpoint:   https://$ACCESS_HOST"
info "Token endpoint: https://$TOKEN_HOST/oauth2/token"

cat <<EOF

The login flow calls SGNL with a Falcon API client. If you don't have one
for this org yet, in the Falcon console for this cloud:
  1. Open API clients and keys (under Support and resources) and create an
     API client with the ${c_bold}sgnl-access:read${c_reset} scope. Use one client per
     Salesforce org.
  2. Copy the client id and secret. The secret is only shown once.
  3. Map the client to your SGNL provider. Without the mapping, Test
     Connection returns HTTP 401 or 403.
You can also leave the client id blank and set it in Setup later.

EOF
prompt "Falcon client id (leave blank to set credentials later in Setup): "
read -r CLIENT_ID
CLIENT_SECRET=""
if [[ -n "$CLIENT_ID" ]]; then
  while [[ -z "$CLIENT_SECRET" ]]; do
    prompt "Falcon client secret: "
    read -rs CLIENT_SECRET
    echo
    [[ -z "$CLIENT_SECRET" ]] && fail "Client secret is required when a client id is given."
  done
fi

heading "Login Flow assignment"

cat <<EOF
Choose the profiles whose users should see the SGNL permission set picker at
login. The script grants each profile the access the flow needs, so users
added to it later are covered too, and can attach the Login Flow to it at the
end. Don't choose the profile your own admin account uses.

Profiles with active users:
EOF
# "Name<TAB>count" per profile; a failed query just means no list.
mapfile -t PROFILE_ROWS < <(sf data query --target-org "$ORG_ALIAS" \
  --query "SELECT Profile.Name, COUNT(Id) FROM User WHERE IsActive = true GROUP BY Profile.Name ORDER BY Profile.Name" \
  --json 2>/dev/null | jq -r '.result.records[]? | select(.Name != null) | "\(.Name)\t\(.expr0)"' || true)
for i in "${!PROFILE_ROWS[@]}"; do
  printf '  %2d) %s (%s active)\n' "$((i + 1))" "${PROFILE_ROWS[$i]%%$'\t'*}" "${PROFILE_ROWS[$i]##*$'\t'}"
done
echo

# Look up the profiles right away, before changing anything, so a typo can be
# fixed here. Any answer that doesn't resolve asks for the whole list again.
PROFILE_NAMES=()
PROFILE_IDS=()
while (( ${#PROFILE_IDS[@]} == 0 )); do
  prompt "Profile numbers or names, separated by commas (e.g. 4,5): "
  read -r PROFILE_INPUT
  IFS=, read -ra PROFILE_CHOICES <<< "$PROFILE_INPUT"
  CHOSEN_NAMES=()
  CHOSEN_IDS=()
  CHOICES_OK=true
  for choice in "${PROFILE_CHOICES[@]}"; do
    # Trim surrounding whitespace.
    choice="${choice#"${choice%%[![:space:]]*}"}"
    choice="${choice%"${choice##*[![:space:]]}"}"
    [[ -z "$choice" ]] && continue
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#PROFILE_ROWS[@]} )); then
      choice="${PROFILE_ROWS[$((choice - 1))]%%$'\t'*}"
    fi
    CHOICE_ID="$(sf data query \
      --target-org "$ORG_ALIAS" \
      --query "SELECT Id FROM Profile WHERE Name='$(soql_escape "$choice")' LIMIT 1" \
      --json 2>/dev/null | jq -r '.result.records[0].Id // empty' || true)"
    if [[ -z "$CHOICE_ID" ]]; then
      fail "Profile '$choice' not found. Use the number from the list, or the profile's name as shown in Setup → Profiles."
      CHOICES_OK=false
      break
    fi
    if [[ -n "$RUNNING_PROFILE_ID" && "$CHOICE_ID" == "$RUNNING_PROFILE_ID" ]]; then
      fail "'$choice' is your own profile. Choose another, or run the script as an admin on a different profile, so a problem with the flow can't lock you out."
      CHOICES_OK=false
      break
    fi
    # Skip a profile chosen twice.
    [[ " ${CHOSEN_IDS[*]} " == *" $CHOICE_ID "* ]] && continue
    CHOSEN_NAMES+=("$choice")
    CHOSEN_IDS+=("$CHOICE_ID")
  done
  if [[ "$CHOICES_OK" == true ]]; then
    if (( ${#CHOSEN_IDS[@]} == 0 )); then
      fail "Choose at least one profile."
    else
      PROFILE_NAMES=("${CHOSEN_NAMES[@]}")
      PROFILE_IDS=("${CHOSEN_IDS[@]}")
    fi
  fi
done

heading "Pre-login evaluation"

prompt "Enable pre-login check now? [y/N]: "
read -r PRELOGIN_ANSWER
PRELOGIN_ENABLED=false
PRELOGIN_ACTION=login
if [[ "$PRELOGIN_ANSWER" =~ ^[Yy]$ ]]; then
  PRELOGIN_ENABLED=true
  while true; do
    prompt "Pre-login action name [default: login]: "
    read -r PRELOGIN_ACTION
    PRELOGIN_ACTION="${PRELOGIN_ACTION:-login}"
    [[ "$PRELOGIN_ACTION" =~ ^[A-Za-z0-9_.:-]+$ ]] && break
    fail "Pre-login action may only contain letters, digits, '_', '.', ':' and '-'."
  done
fi

# -----------------------------------------------------------------------------
# Look up the profiles' metadata names and the Org Id before changing anything
# -----------------------------------------------------------------------------
# Profile metadata files use the API name (Standard User is "Standard"), not
# the display name.
PROFILE_MD_JSON="$(sf org list metadata --metadata-type Profile --target-org "$ORG_ALIAS" --json 2>/dev/null || true)"
PROFILE_API_NAMES=()
for i in "${!PROFILE_IDS[@]}"; do
  API_NAME="$(NGIS_PROFILE_ID="${PROFILE_IDS[$i]}" jq -r '.result[]? | select(.id == env.NGIS_PROFILE_ID) | .fullName' <<<"$PROFILE_MD_JSON" 2>/dev/null | head -1 || true)"
  [[ -z "$API_NAME" ]] && die "Could not find the metadata name for profile '${PROFILE_NAMES[$i]}'."
  PROFILE_API_NAMES+=("$API_NAME")
done

# The flow sends <15-char Org Id>_search / _evaluate as context.routingKey;
# the SGNL admin needs both values for the provider hook's integration
# assignments.
ORG_ID="$(sf data query \
  --target-org "$ORG_ALIAS" \
  --query "SELECT Id FROM Organization LIMIT 1" \
  --json 2>/dev/null | jq -r '.result.records[0].Id // empty')"
if [[ "$ORG_ID" =~ ^00D[A-Za-z0-9]{12}([A-Za-z0-9]{3})?$ ]]; then
  CONTEXT_ORG_SEARCH="${ORG_ID:0:15}_search"
  CONTEXT_ORG_EVALUATE="${ORG_ID:0:15}_evaluate"
else
  warn "Could not read the Org Id; the admin page shows the SGNL provider hook values."
  CONTEXT_ORG_SEARCH="(see the admin page)"
  CONTEXT_ORG_EVALUATE="(see the admin page)"
fi

# -----------------------------------------------------------------------------
# Confirmation
# -----------------------------------------------------------------------------
heading "Summary"
cat <<EOF
  Org alias:           $ORG_ALIAS
  Running user:        $RUNNING_USER_NAME
  Access host:         $ACCESS_HOST
  Token host:          $TOKEN_HOST
  Client credentials:  $( [[ -n "$CLIENT_ID" ]] && echo "supplied" || echo "not supplied; set in Setup later" )
  Pre-login enabled:   $PRELOGIN_ENABLED  (action: $PRELOGIN_ACTION)
  Login Flow profiles:
EOF
for i in "${!PROFILE_IDS[@]}"; do
  printf '    %s (%s, %s)\n' "${PROFILE_NAMES[$i]}" "${PROFILE_API_NAMES[$i]}" "${PROFILE_IDS[$i]}"
done
echo
prompt "Proceed? [y/N]: "
read -r GO
[[ "$GO" =~ ^[Yy]$ ]] || die "Aborted."

# -----------------------------------------------------------------------------
# Step 1: Stage a copy of the project with this cloud's hosts
# -----------------------------------------------------------------------------
heading "1. Staging project"

STAGE_DIR="$WORK_DIR/project"
mkdir -p "$STAGE_DIR"
cp -R "$REPO_ROOT/sfdx-project.json" "$REPO_ROOT/.forceignore" \
      "$REPO_ROOT/force-app" "$REPO_ROOT/sgnl-credentials" "$STAGE_DIR/"

NC_FILE="$STAGE_DIR/sgnl-credentials/main/default/namedCredentials/NGIS_SGNL_Access.namedCredential-meta.xml"
EC_FILE="$STAGE_DIR/sgnl-credentials/main/default/externalCredentials/$EXTERNAL_CREDENTIAL.externalCredential-meta.xml"

# Hosts are validated against ACCESS_HOST_PATTERN, so they're safe in sed.
sed "s|https://access.crowdstrike.com|https://$ACCESS_HOST|" "$NC_FILE" > "$NC_FILE.tmp" && mv "$NC_FILE.tmp" "$NC_FILE"
sed "s|https://api.crowdstrike.com/oauth2/token|https://$TOKEN_HOST/oauth2/token|" "$EC_FILE" > "$EC_FILE.tmp" && mv "$EC_FILE.tmp" "$EC_FILE"

grep -q "https://$ACCESS_HOST<" "$NC_FILE" || die "Failed to patch the Named Credential URL."
grep -q "https://$TOKEN_HOST/oauth2/token<" "$EC_FILE" || die "Failed to patch the External Credential token URL."
ok "Staged with https://$ACCESS_HOST and https://$TOKEN_HOST/oauth2/token"

# The flow's page and Apex classes are granted on each profile, so every user
# on it has them, including users added later. A Profile deploy changes only
# the elements in the file. The credential access can't go in Profile
# metadata; step 4 grants it through the API.
PROFILE_DIR="$STAGE_DIR/force-app/main/default/profiles"
mkdir -p "$PROFILE_DIR"
for i in "${!PROFILE_IDS[@]}"; do
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<Profile xmlns="http://soap.sforce.com/2006/04/metadata">'
    for cls in "${LOGIN_FLOW_CLASSES[@]}"; do
      printf '    <classAccesses>\n        <apexClass>%s</apexClass>\n        <enabled>true</enabled>\n    </classAccesses>\n' "$cls"
    done
    printf '    <pageAccesses>\n        <apexPage>%s</apexPage>\n        <enabled>true</enabled>\n    </pageAccesses>\n' "$LOGIN_FLOW_PAGE"
    echo '</Profile>'
  } > "$PROFILE_DIR/${PROFILE_API_NAMES[$i]}.profile-meta.xml"
  ok "Staged page and Apex class access for profile '${PROFILE_NAMES[$i]}'"
done

# The flow reads its settings from LoginFlow_Config.Default. Save every
# setting, so admins see real values when they edit the record in Setup. A new
# record gets all four. An existing record keeps the values it has: blank
# fields get the default, and the pre-login fields change only if the operator
# asks. On first install the type doesn't exist yet, so a failed query counts
# as no record.
CFG_JSON="$(sf data query --target-org "$ORG_ALIAS" \
  --query "SELECT Pre_Login_Check_Enabled__c, Pre_Login_Action__c, Denial_Message__c, Denial_Auto_Logout_Seconds__c FROM LoginFlow_Config__mdt WHERE DeveloperName='Default'" \
  --json 2>/dev/null || true)"
EXISTING_CFG="$(jq -r '.result.totalSize // 0' <<<"$CFG_JSON" 2>/dev/null || true)"
cfg_field() { jq -r ".result.records[0].$1 // empty" <<<"$CFG_JSON" 2>/dev/null || true; }

CMT_DIR="$STAGE_DIR/force-app/main/default/customMetadata"
CMT_FILE="$CMT_DIR/LoginFlow_Config.Default.md-meta.xml"
# Keep in sync with LoginFlowConfig.DEFAULT_DENY_MSG and DEFAULT_DENY_SECONDS.
DEFAULT_DENY_MSG='Your account is not authorized to access this org right now. You will be signed out automatically.'
DEFAULT_DENY_SECONDS=10

CMT_VALUES=""
CMT_FIELDS=""
cmt_value() {  # field, xsd type, value
  CMT_VALUES+="    <values>
        <field>$1</field>
        <value xsi:type=\"$2\">$3</value>
    </values>
"
  CMT_FIELDS+="${CMT_FIELDS:+, }$1"
}

if [[ "$EXISTING_CFG" != "1" ]]; then
  PRELOGIN_EFFECTIVE="$PRELOGIN_ENABLED"
  cmt_value Pre_Login_Check_Enabled__c xsd:boolean "$PRELOGIN_ENABLED"
  cmt_value Pre_Login_Action__c xsd:string "$PRELOGIN_ACTION"
  cmt_value Denial_Message__c xsd:string "$DEFAULT_DENY_MSG"
  cmt_value Denial_Auto_Logout_Seconds__c xsd:double "$DEFAULT_DENY_SECONDS"
else
  # jq's // treats false as missing, so a disabled check reads as empty.
  PRELOGIN_EFFECTIVE=false
  [[ "$(cfg_field Pre_Login_Check_Enabled__c)" == true ]] && PRELOGIN_EFFECTIVE=true
  if [[ "$PRELOGIN_ENABLED" == true ]]; then
    prompt "A Default config record already exists. Overwrite its pre-login fields? [y/N]: "
    read -r OVERWRITE
    if [[ "$OVERWRITE" =~ ^[Yy]$ ]]; then
      PRELOGIN_EFFECTIVE=true
      cmt_value Pre_Login_Check_Enabled__c xsd:boolean true
      cmt_value Pre_Login_Action__c xsd:string "$PRELOGIN_ACTION"
    fi
  fi
  if [[ -z "$(cfg_field Pre_Login_Action__c)" && "$CMT_FIELDS" != *Pre_Login_Action__c* ]]; then
    cmt_value Pre_Login_Action__c xsd:string login
  fi
  if [[ -z "$(cfg_field Denial_Message__c)" ]]; then
    cmt_value Denial_Message__c xsd:string "$DEFAULT_DENY_MSG"
  fi
  if [[ -z "$(cfg_field Denial_Auto_Logout_Seconds__c)" ]]; then
    cmt_value Denial_Auto_Logout_Seconds__c xsd:double "$DEFAULT_DENY_SECONDS"
  fi
fi

if [[ -n "$CMT_VALUES" ]]; then
  mkdir -p "$CMT_DIR"
  # Only the fields listed are written; other fields keep their values.
  cat > "$CMT_FILE" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <label>Default</label>
    <protected>false</protected>
${CMT_VALUES}</CustomMetadata>
XML
  ok "Staged LoginFlow_Config.Default: $CMT_FIELDS"
else
  info "The Default config record already has every setting; leaving it unchanged."
fi

# -----------------------------------------------------------------------------
# Step 2: Deploy
# -----------------------------------------------------------------------------
heading "2. Deploying metadata"

info "Deploying force-app and sgnl-credentials to $ORG_ALIAS..."
if ! (cd "$STAGE_DIR" && sf project deploy start \
    --source-dir force-app \
    --source-dir sgnl-credentials \
    --target-org "$ORG_ALIAS" \
    --ignore-conflicts \
    --wait 30) > "$WORK_DIR/deploy.log" 2>&1; then
  cat "$WORK_DIR/deploy.log"
  die "Deploy failed. See output above."
fi
ok "Metadata deploy succeeded."

# -----------------------------------------------------------------------------
# Step 3: Set the OAuth client credentials on the principal
# -----------------------------------------------------------------------------
heading "3. External Credential principal"

manual_credential_steps() {
  warn "Set the credentials manually:"
  warn "  Setup → Named Credentials → External Credentials → $EXTERNAL_CREDENTIAL"
  warn "  → Principals → $PRINCIPAL_NAME → Edit → Client ID and Client Secret"
  warn "Then click Test Connection on the admin page before attaching the Login Flow."
}

if [[ -z "$CLIENT_ID" ]]; then
  warn "Skipping: no client credentials supplied."
  manual_credential_steps
else
  CRED_FILE="$WORK_DIR/credential.json"
  CRED_PATH="/services/data/v$API_VERSION/named-credentials/credential/"
  # Values come in through the environment so the secret never appears in a
  # process argument list.
  NGIS_CLIENT_ID="$CLIENT_ID" NGIS_CLIENT_SECRET="$CLIENT_SECRET" \
  NGIS_EC="$EXTERNAL_CREDENTIAL" NGIS_PRINCIPAL="$PRINCIPAL_NAME" \
    jq -n '{
      externalCredential: env.NGIS_EC,
      principalName: env.NGIS_PRINCIPAL,
      principalType: "NamedPrincipal",
      credentials: {
        clientId: { value: env.NGIS_CLIENT_ID, encrypted: false },
        clientSecret: { value: env.NGIS_CLIENT_SECRET, encrypted: true }
      }
    }' > "$CRED_FILE"

  # POST creates the credential; PUT updates one that already exists.
  if sf api request rest "$CRED_PATH" --method POST --body "@$CRED_FILE" \
      --target-org "$ORG_ALIAS" > "$WORK_DIR/cred.log" 2>&1; then
    ok "Client credentials set."
  elif sf api request rest "$CRED_PATH" --method PUT --body "@$CRED_FILE" \
      --target-org "$ORG_ALIAS" > "$WORK_DIR/cred.log" 2>&1; then
    ok "Client credentials updated."
  else
    cat "$WORK_DIR/cred.log"
    warn "Could not set the client credentials."
    manual_credential_steps
  fi
  rm -f "$CRED_FILE"
fi

# -----------------------------------------------------------------------------
# Step 4: Access
# -----------------------------------------------------------------------------
heading "4. Granting access"

ADMIN_PS_ID="$(sf data query --target-org "$ORG_ALIAS" \
  --query "SELECT Id FROM PermissionSet WHERE Name='$ADMIN_PERMSET' LIMIT 1" \
  --json 2>/dev/null | jq -r '.result.records[0].Id // empty')"

if [[ -z "$ADMIN_PS_ID" ]]; then
  warn "$ADMIN_PERMSET not found (should have deployed). Skipping."
else
  EXISTING_ASSIGN="$(sf data query --target-org "$ORG_ALIAS" \
    --query "SELECT Id FROM PermissionSetAssignment WHERE PermissionSetId='$ADMIN_PS_ID' AND AssigneeId='$RUNNING_USER_ID'" \
    --json 2>/dev/null | jq -r '.result.records[0].Id // empty')"
  if [[ -n "$EXISTING_ASSIGN" ]]; then
    ok "$ADMIN_PERMSET already assigned to $RUNNING_USER_NAME."
  elif sf data create record --sobject PermissionSetAssignment \
      --values "PermissionSetId=$ADMIN_PS_ID AssigneeId=$RUNNING_USER_ID" \
      --target-org "$ORG_ALIAS" > "$WORK_DIR/psa.log" 2>&1; then
    ok "Assigned $ADMIN_PERMSET to $RUNNING_USER_NAME."
  else
    cat "$WORK_DIR/psa.log"
    warn "Admin permission set assignment failed; assign it manually from Setup → Permission Sets."
  fi
fi

# Each profile also needs the External Credential principal access, or the
# flow's SGNL calls fail for its users. Profile metadata can't carry it, so it
# goes on the permission set every profile owns (IsOwnedByProfile) as a
# SetupEntityAccess row. The principal isn't queryable directly; the admin
# permission set grants it, so its row gives the principal's Id.
manual_profile_credential_steps() {
  warn "Grant it manually: Setup → Profiles → $1 → Enabled External Credential"
  warn "  Principal Access → Edit → add $EXTERNAL_CREDENTIAL - $PRINCIPAL_NAME"
}

PRINCIPAL_ENTITY_ID="$(sf data query --target-org "$ORG_ALIAS" \
  --query "SELECT SetupEntityId FROM SetupEntityAccess WHERE Parent.Name = '$ADMIN_PERMSET' AND SetupEntityType = 'ExternalCredentialParameter' LIMIT 1" \
  --json 2>/dev/null | jq -r '.result.records[0].SetupEntityId // empty' || true)"

# PROFILE_ACCESS[i] is true once profile i has every grant the flow needs.
PROFILE_ACCESS=()
for i in "${!PROFILE_IDS[@]}"; do
  P_NAME="${PROFILE_NAMES[$i]}"
  PROFILE_ACCESS[i]=false
  PROFILE_PS_ID="$(sf data query --target-org "$ORG_ALIAS" \
    --query "SELECT Id FROM PermissionSet WHERE IsOwnedByProfile = true AND ProfileId = '${PROFILE_IDS[$i]}' LIMIT 1" \
    --json 2>/dev/null | jq -r '.result.records[0].Id // empty' || true)"

  # Both Ids go back into a command, so only accept the expected key prefixes.
  if [[ ! "$PROFILE_PS_ID" =~ ^0PS[A-Za-z0-9]{12}([A-Za-z0-9]{3})?$ || ! "$PRINCIPAL_ENTITY_ID" =~ ^0pu[A-Za-z0-9]{12}([A-Za-z0-9]{3})?$ ]]; then
    warn "Could not look up profile '$P_NAME' or the credential principal, so the profile doesn't have credential access yet."
    manual_profile_credential_steps "$P_NAME"
    continue
  fi
  EXISTING_GRANT="$(sf data query --target-org "$ORG_ALIAS" \
    --query "SELECT Id FROM SetupEntityAccess WHERE ParentId = '$PROFILE_PS_ID' AND SetupEntityId = '$PRINCIPAL_ENTITY_ID'" \
    --json 2>/dev/null | jq -r '.result.records[0].Id // empty' || true)"
  if [[ -n "$EXISTING_GRANT" ]]; then
    PROFILE_ACCESS[i]=true
    ok "Profile '$P_NAME' already has credential access."
  elif sf data create record --sobject SetupEntityAccess \
      --values "ParentId=$PROFILE_PS_ID SetupEntityId=$PRINCIPAL_ENTITY_ID" \
      --target-org "$ORG_ALIAS" > "$WORK_DIR/profile_grant.log" 2>&1; then
    PROFILE_ACCESS[i]=true
    ok "Granted credential access to profile '$P_NAME'."
  else
    cat "$WORK_DIR/profile_grant.log"
    warn "Could not grant credential access to profile '$P_NAME'."
    manual_profile_credential_steps "$P_NAME"
  fi
done

# -----------------------------------------------------------------------------
# Step 5: Test Connection
# -----------------------------------------------------------------------------
# Runs the admin page's Test Connection as the running user, who now has the
# admin permission set and so the credential access. It runs even when no
# client id was entered on this run, so a re-run tests the credentials already
# saved in the org. It only passes once the credentials are set and the SGNL
# provider hook routes this org. A failure doesn't stop the script; step 6
# warns before attaching the Login Flow.
heading "5. Test Connection"

TEST_PASSED=false
[[ -z "$CLIENT_ID" ]] && info "No client credentials entered on this run; testing the ones saved in the org, if any."
cat <<EOF
Test Connection calls SGNL as you. It passes only after the SGNL provider
hook has the application Id path {\$.context.routingKey} and two integration
assignments for this org's Protected System, neither with a transform:
  Search (asset search):
    $CONTEXT_ORG_SEARCH
  Evaluate (access evaluation):
    $CONTEXT_ORG_EVALUATE

EOF
prompt "Run Test Connection now? [Y/n]: "
read -r RUN_TEST
if [[ "$RUN_TEST" =~ ^[Nn]$ ]]; then
  info "Skipped. You can run it later from the admin page."
else
  cat > "$WORK_DIR/test_connection.apex" <<'APEX'
LoginFlowAdminController.TestResultDTO r = LoginFlowAdminController.testConnection();
System.debug('NGIS_TEST=' + r.statusCode + '/' + r.ok);
System.debug('NGIS_HINT=' + r.hintText);
System.debug('NGIS_BODY=' + (r.body == null ? '' : r.body.abbreviate(500)));
APEX
  if ! sf apex run --file "$WORK_DIR/test_connection.apex" --target-org "$ORG_ALIAS" \
      > "$WORK_DIR/test_connection.log" 2>&1; then
    cat "$WORK_DIR/test_connection.log"
    warn "Could not run Test Connection. Use the button on the admin page instead."
  else
    TEST_RESULT="$(grep -oE 'NGIS_TEST=[0-9]+/(true|false)' "$WORK_DIR/test_connection.log" | head -1 | cut -d= -f2 || true)"
    TEST_STATUS="${TEST_RESULT%/*}"
    if [[ "${TEST_RESULT#*/}" == true ]]; then
      TEST_PASSED=true
      ok "Test Connection passed (HTTP $TEST_STATUS)."
    else
      fail "Test Connection failed (HTTP ${TEST_STATUS:-unknown})."
      # Match the debug output, not the echoed source lines.
      TEST_HINT="$(grep -oE '\|DEBUG\|NGIS_HINT=.*' "$WORK_DIR/test_connection.log" | head -1 | cut -d= -f2- || true)"
      TEST_BODY="$(grep -oE '\|DEBUG\|NGIS_BODY=.*' "$WORK_DIR/test_connection.log" | head -1 | cut -d= -f2- || true)"
      [[ -n "$TEST_HINT" && "$TEST_HINT" != null ]] && warn "$TEST_HINT"
      [[ -n "$TEST_BODY" ]] && info "Response: $TEST_BODY"
      info "Continuing. Fix this, then rerun the script or use Test Connection on the admin page."
    fi
  fi
fi

# -----------------------------------------------------------------------------
# Step 6: Attach the Login Flow
# -----------------------------------------------------------------------------
# Lockout ordering: attach only to a profile that has all the access, and only
# if the operator says so. If Test Connection didn't pass, the operator can
# still attach, after a warning about what users will see. A profile has at
# most one Login Flow, which lives in Profile metadata (LoginFlow isn't
# available through the REST or Tooling API), so read each profile first to
# see what's there.
heading "6. Login Flow"

# Comma-separated display names, for the closing steps.
join_names() { local IFS=,; printf '%s' "$*" | sed 's/,/, /g'; }

if [[ "$TEST_PASSED" != true ]]; then
  warn "Test Connection didn't pass. You can still attach the Login Flow, but until SGNL is reachable:"
  if [[ "$PRELOGIN_EFFECTIVE" == true ]]; then
    warn "  ${c_bold}the pre-login check is on, so every user on an attached profile is denied and signed out.${c_reset}"
  else
    warn "  users on an attached profile can still log in, but get no permission sets."
  fi
fi

ATTACHED_NAMES=()
NOT_ATTACHED_NAMES=()
NO_ACCESS_NAMES=()
for i in "${!PROFILE_IDS[@]}"; do
  P_NAME="${PROFILE_NAMES[$i]}"
  P_API="${PROFILE_API_NAMES[$i]}"
  if [[ "${PROFILE_ACCESS[$i]}" != true ]]; then
    NO_ACCESS_NAMES+=("$P_NAME")
    info "Not attaching the Login Flow to '$P_NAME': the profile doesn't have all its access yet."
    continue
  fi

  CURRENT_FLOW_PAGE=""
  RETRIEVE_DIR="$WORK_DIR/profile_retrieve_$i"
  if (cd "$STAGE_DIR" && sf project retrieve start --metadata "Profile:$P_API" \
      --target-org "$ORG_ALIAS" --target-metadata-dir "$RETRIEVE_DIR" --unzip) \
      > "$WORK_DIR/profile_retrieve.log" 2>&1; then
    PROFILE_FILE="$(find "$RETRIEVE_DIR" -name '*.profile' 2>/dev/null | head -1 || true)"
    if [[ -n "$PROFILE_FILE" ]] && grep -q '<loginFlows>' "$PROFILE_FILE"; then
      # A Flow-based Login Flow has no vfFlowPage; grep then finds nothing.
      CURRENT_FLOW_PAGE="$(grep -oE '<vfFlowPage>[^<]*' "$PROFILE_FILE" | head -1 | cut -d'>' -f2 || true)"
      CURRENT_FLOW_PAGE="${CURRENT_FLOW_PAGE:-(a Flow-based login flow)}"
    fi
  else
    warn "Could not read profile '$P_NAME' to check for an existing Login Flow."
    CURRENT_FLOW_PAGE="(unknown)"
  fi

  ATTACH=false
  if [[ "$CURRENT_FLOW_PAGE" == "$LOGIN_FLOW_PAGE" ]]; then
    ATTACHED_NAMES+=("$P_NAME")
    ok "The Login Flow is already attached to '$P_NAME'."
    continue
  elif [[ -n "$CURRENT_FLOW_PAGE" ]]; then
    warn "Profile '$P_NAME' already has a Login Flow: $CURRENT_FLOW_PAGE."
    prompt "Replace it with the SGNL Login Flow? [y/N]: "
    read -r REPLACE_FLOW
    [[ "$REPLACE_FLOW" =~ ^[Yy]$ ]] && ATTACH=true
  else
    prompt "Attach the Login Flow to '$P_NAME' now? Its users see it at their next login. [y/N]: "
    read -r ATTACH_FLOW
    [[ "$ATTACH_FLOW" =~ ^[Yy]$ ]] && ATTACH=true
  fi

  if [[ "$ATTACH" != true ]]; then
    NOT_ATTACHED_NAMES+=("$P_NAME")
    info "Not attaching the Login Flow to '$P_NAME'."
    continue
  fi

  # A separate deploy with only the profile's loginFlows element.
  ATTACH_DIR="$WORK_DIR/attach_$i"
  mkdir -p "$ATTACH_DIR/force-app/main/default/profiles" "$ATTACH_DIR/sgnl-credentials"
  cp "$REPO_ROOT/sfdx-project.json" "$ATTACH_DIR/"
  cat > "$ATTACH_DIR/force-app/main/default/profiles/$P_API.profile-meta.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<Profile xmlns="http://soap.sforce.com/2006/04/metadata">
    <loginFlows>
        <flowType>UI</flowType>
        <friendlyName>SGNL Permission Set Selection</friendlyName>
        <uiLoginFlowType>VisualForce</uiLoginFlowType>
        <useLightningRuntime>false</useLightningRuntime>
        <vfFlowPage>$LOGIN_FLOW_PAGE</vfFlowPage>
        <vfFlowPageTitle>$LOGIN_FLOW_PAGE</vfFlowPageTitle>
    </loginFlows>
</Profile>
XML
  if (cd "$ATTACH_DIR" && sf project deploy start --source-dir force-app \
      --target-org "$ORG_ALIAS" --ignore-conflicts --wait 30) > "$WORK_DIR/attach.log" 2>&1; then
    ATTACHED_NAMES+=("$P_NAME")
    ok "Attached the Login Flow to '$P_NAME'."
  else
    cat "$WORK_DIR/attach.log"
    NOT_ATTACHED_NAMES+=("$P_NAME")
    warn "Could not attach the Login Flow to '$P_NAME'. Attach it in Setup instead (see the steps below)."
  fi
done

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
heading "Done"

if [[ "$TEST_PASSED" == true ]]; then
  TEST_STEP="  2. Test Connection passed. To recheck later, open the admin page and
     click \"Test Connection\".
     ${c_dim}sf org open --target-org $ORG_ALIAS --path /lightning/n/Login_Flow_Admin${c_reset}"
else
  TEST_STEP="  2. ${c_bold}Test Connection hasn't passed yet.${c_reset} Set the client credentials if
     you skipped them, then open the admin page and click \"Test Connection\".
     It should return HTTP 200 and a JSON body listing your permission sets.
     ${c_dim}sf org open --target-org $ORG_ALIAS --path /lightning/n/Login_Flow_Admin${c_reset}"
fi

FLOW_STEP="  3."
if (( ${#ATTACHED_NAMES[@]} > 0 )); then
  FLOW_STEP+=" The Login Flow is attached to: $(join_names "${ATTACHED_NAMES[@]}").
    "
fi
# Profiles missing access are left out here; step 4 says to grant it first.
if (( ${#NOT_ATTACHED_NAMES[@]} > 0 )); then
  FLOW_STEP+=" Not attached yet: $(join_names "${NOT_ATTACHED_NAMES[@]}"). To attach it, rerun
     this script, or Setup → Identity → Login Flows → New. Flow Type
     \"Visualforce Page\", page $LOGIN_FLOW_PAGE, then assign it to each
     profile. Run Test Connection first.
    "
fi
FLOW_STEP+=" Keep an admin on a profile without the flow."

if (( ${#NO_ACCESS_NAMES[@]} == 0 )); then
  ACCESS_STEP="  4. The profiles have the access the flow needs, so users added to them
     later are covered. To use the flow on another profile, rerun this script
     and choose it."
else
  ACCESS_STEP="  4. ${c_bold}No credential access yet: $(join_names "${NO_ACCESS_NAMES[@]}").${c_reset} Grant it in
     Setup → Profiles → (profile) → Enabled External Credential Principal
     Access, or rerun this script. Don't attach the Login Flow to these
     profiles until then: the flow can't call SGNL for their users."
fi

cat <<EOF
${c_green}${c_bold}Login flow bootstrapped.${c_reset}

Next steps:

  1. On the SGNL provider hook, set the application Id path to
     {\$.context.routingKey}, then create two integration assignments for
     this org's Protected System, with these application Ids and no
     transform:
       Search (asset search):
         $CONTEXT_ORG_SEARCH
       Evaluate (access evaluation):
         $CONTEXT_ORG_EVALUATE
     The admin page shows the same values.

$TEST_STEP

$FLOW_STEP

$ACCESS_STEP

  5. Test the flow: log in with a user on one of the profiles. They should
     see the permission set picker after authenticating.

EOF
