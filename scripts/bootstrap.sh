#!/usr/bin/env bash
#
# Bootstrap the SGNL login flow into a Salesforce org.
#
# Prompts for the Falcon cloud and OAuth client credentials, deploys all
# metadata (with the cloud's hosts patched into a temporary copy of the
# project), sets the client id/secret on the External Credential principal,
# and assigns the permission sets. Attaching the Login Flow to the profile is
# a Setup step it prints at the end: LoginFlow isn't available through the
# REST or Tooling API.
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
USER_PERMSET="NGIS_SGNL_Login_Flow_User"
ADMIN_PERMSET="NGIS_SGNL_Login_Flow_Admin"
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
Choose the profile whose users should see the SGNL permission set picker at
login. Its active users get the $USER_PERMSET permission set now, and
you attach the Login Flow to this profile at the end. Don't choose the
profile your own admin account uses.

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

# Look up the profile right away, before changing anything, so a typo can be
# fixed here.
PROFILE_ID=""
while [[ -z "$PROFILE_ID" ]]; do
  prompt "Profile number or name: "
  read -r PROFILE_NAME
  if [[ "$PROFILE_NAME" =~ ^[0-9]+$ ]] && (( PROFILE_NAME >= 1 && PROFILE_NAME <= ${#PROFILE_ROWS[@]} )); then
    PROFILE_NAME="${PROFILE_ROWS[$((PROFILE_NAME - 1))]%%$'\t'*}"
  fi
  if [[ -z "$PROFILE_NAME" ]]; then
    fail "Profile is required."
    continue
  fi
  PROFILE_ID="$(sf data query \
    --target-org "$ORG_ALIAS" \
    --query "SELECT Id FROM Profile WHERE Name='$(soql_escape "$PROFILE_NAME")' LIMIT 1" \
    --json 2>/dev/null | jq -r '.result.records[0].Id // empty' || true)"
  [[ -z "$PROFILE_ID" ]] && fail "Profile '$PROFILE_NAME' not found. Use the profile's name as shown in Setup → Profiles."
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
# Look up the Org Id before changing anything
# -----------------------------------------------------------------------------
PROFILE_ID="$(sf data query \
  --target-org "$ORG_ALIAS" \
  --query "SELECT Id FROM Profile WHERE Name='$(soql_escape "$PROFILE_NAME")' LIMIT 1" \
  --json 2>/dev/null | jq -r '.result.records[0].Id // empty')"
[[ -z "$PROFILE_ID" ]] && die "Profile '$PROFILE_NAME' not found."

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
  Login Flow profile:  $PROFILE_NAME ($PROFILE_ID)
  Pre-login enabled:   $PRELOGIN_ENABLED  (action: $PRELOGIN_ACTION)

EOF
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

# The flow reads its settings from LoginFlow_Config.Default. Save every
# setting, so admins see real values when they edit the record in Setup. A new
# record gets all four. An existing record keeps the values it has: blank
# fields get the default, and the pre-login fields change only if the operator
# asks. On first install the type doesn't exist yet, so a failed query counts
# as no record.
CFG_JSON="$(sf data query --target-org "$ORG_ALIAS" \
  --query "SELECT Pre_Login_Action__c, Denial_Message__c, Denial_Auto_Logout_Seconds__c FROM LoginFlow_Config__mdt WHERE DeveloperName='Default'" \
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
  cmt_value Pre_Login_Check_Enabled__c xsd:boolean "$PRELOGIN_ENABLED"
  cmt_value Pre_Login_Action__c xsd:string "$PRELOGIN_ACTION"
  cmt_value Denial_Message__c xsd:string "$DEFAULT_DENY_MSG"
  cmt_value Denial_Auto_Logout_Seconds__c xsd:double "$DEFAULT_DENY_SECONDS"
else
  if [[ "$PRELOGIN_ENABLED" == true ]]; then
    prompt "A Default config record already exists. Overwrite its pre-login fields? [y/N]: "
    read -r OVERWRITE
    if [[ "$OVERWRITE" =~ ^[Yy]$ ]]; then
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
# Step 4: Permission sets
# -----------------------------------------------------------------------------
heading "4. Assigning permission sets"

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

# Every user who hits the login flow needs the user permission set before the
# flow is attached. It's the only grant for the LoginFlowPermSets page, so
# without it the user gets Insufficient Privileges and can't log in.
#
# Users are assigned in pages ordered by Id, one anonymous Apex run per page,
# so large profiles stay under the per-transaction limits (10,000 DML rows,
# 50,000 query rows). Paging by Id also means users whose assignment fails
# (e.g. a license mismatch) don't stall the loop.
ASSIGN_PAGE_SIZE=5000
LAST_USER_ID=""
TOTAL_ADDED=0
TOTAL_NEEDED=0
PAGE_NUM=0
while true; do
  PAGE_NUM=$((PAGE_NUM + 1))
  ID_FILTER=""
  [[ -n "$LAST_USER_ID" ]] && ID_FILTER="AND Id > '$LAST_USER_ID'"

  cat > "$WORK_DIR/assign_users.apex" <<APEX
Id psId = [SELECT Id FROM PermissionSet WHERE Name = '$USER_PERMSET' LIMIT 1].Id;
List<User> users = [SELECT Id FROM User WHERE ProfileId = '$PROFILE_ID' AND IsActive = true $ID_FILTER ORDER BY Id LIMIT $ASSIGN_PAGE_SIZE];
Set<Id> userIds = new Map<Id, User>(users).keySet();
Set<Id> already = new Set<Id>();
for (PermissionSetAssignment a : [SELECT AssigneeId FROM PermissionSetAssignment WHERE PermissionSetId = :psId AND AssigneeId IN :userIds]) {
    already.add(a.AssigneeId);
}
List<PermissionSetAssignment> toAdd = new List<PermissionSetAssignment>();
for (User u : users) {
    if (!already.contains(u.Id)) {
        toAdd.add(new PermissionSetAssignment(PermissionSetId = psId, AssigneeId = u.Id));
    }
}
Integer added = 0;
for (Database.SaveResult r : Database.insert(toAdd, false)) {
    if (r.isSuccess()) { added++; }
}
String lastId = users.isEmpty() ? '' : String.valueOf(users[users.size() - 1].Id);
System.debug('NGIS_PAGE=' + users.size() + '/' + added + '/' + toAdd.size() + '/' + lastId);
APEX

  if ! sf apex run --file "$WORK_DIR/assign_users.apex" --target-org "$ORG_ALIAS" \
      > "$WORK_DIR/assign_users.log" 2>&1; then
    cat "$WORK_DIR/assign_users.log"
    die "Failed to assign $USER_PERMSET (page $PAGE_NUM). Don't attach the Login Flow until every user on the profile has it."
  fi

  PAGE_RESULT="$(grep -oE 'NGIS_PAGE=[0-9]+/[0-9]+/[0-9]+/[A-Za-z0-9]*' "$WORK_DIR/assign_users.log" | head -1 | cut -d= -f2 || true)"
  if [[ -z "$PAGE_RESULT" ]]; then
    cat "$WORK_DIR/assign_users.log"
    die "Could not read the assignment result (page $PAGE_NUM). Don't attach the Login Flow until every user on the profile has it."
  fi
  IFS=/ read -r PAGE_USERS PAGE_ADDED PAGE_NEEDED PAGE_LAST_ID <<< "$PAGE_RESULT"

  TOTAL_ADDED=$((TOTAL_ADDED + PAGE_ADDED))
  TOTAL_NEEDED=$((TOTAL_NEEDED + PAGE_NEEDED))
  info "Page $PAGE_NUM: $PAGE_USERS users, added $PAGE_ADDED of $PAGE_NEEDED needed."

  # A short page is the last one.
  (( PAGE_USERS < ASSIGN_PAGE_SIZE )) && break

  # The cursor goes back into SOQL, so only accept a User Id.
  [[ "$PAGE_LAST_ID" =~ ^005[A-Za-z0-9]{12}([A-Za-z0-9]{3})?$ ]] \
    || die "Unexpected user Id '$PAGE_LAST_ID' (page $PAGE_NUM). Don't attach the Login Flow until every user on the profile has it."
  LAST_USER_ID="$PAGE_LAST_ID"
done

ok "Assigned $USER_PERMSET to active '$PROFILE_NAME' users (added/needed: $TOTAL_ADDED/$TOTAL_NEEDED)."
if (( TOTAL_ADDED != TOTAL_NEEDED )); then
  warn "Some assignments failed (often a license mismatch). Check those users before relying on the flow."
fi

# -----------------------------------------------------------------------------
# Step 5: Test Connection
# -----------------------------------------------------------------------------
# Runs the admin page's Test Connection as the running user, who now has the
# admin permission set and so the credential access. It only passes once the
# credentials are set and the SGNL provider hook routes this org.
heading "5. Test Connection"

TEST_PASSED=false
if [[ -z "$CLIENT_ID" ]]; then
  warn "Skipping: no client credentials supplied."
else
  cat <<EOF
Test Connection calls SGNL as you. It passes only after the SGNL provider
hook has the application Id path {\$.context.routingKey} and two integration
assignments for this org's Protected System:
  Search (list permission sets, with the permission set transform):
    $CONTEXT_ORG_SEARCH
  Evaluate (access evaluation):
    $CONTEXT_ORG_EVALUATE

EOF
  prompt "Run Test Connection now? [Y/n]: "
  read -r RUN_TEST
  if [[ "$RUN_TEST" =~ ^[Nn]$ ]]; then
    info "Skipped. Run Test Connection on the admin page before attaching the Login Flow."
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
        warn "Fix this before attaching the Login Flow, then rerun the script or use Test Connection on the admin page."
      fi
    fi
  fi
fi

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

cat <<EOF
${c_green}${c_bold}Login flow bootstrapped.${c_reset}

Next steps:

  1. On the SGNL provider hook, set the application Id path to
     {\$.context.routingKey}, then create two integration assignments for
     this org's Protected System, with these application Ids:
       Search (list permission sets, with the permission set transform):
         $CONTEXT_ORG_SEARCH
       Evaluate (access evaluation):
         $CONTEXT_ORG_EVALUATE
     The admin page shows the same values.

$TEST_STEP

  3. Only after Test Connection succeeds, attach the Login Flow:
     Setup → Identity → Login Flows → New. Flow Type "Visualforce Page",
     page LoginFlowPermSets, profile '$PROFILE_NAME'. Keep an admin on a
     profile without the flow.

  4. Assign $USER_PERMSET to users added to '$PROFILE_NAME' later,
     before they log in. Without it they get Insufficient Privileges and
     can't log in.

  5. Test the flow: log in with a user on '$PROFILE_NAME'. They should see
     the permission set picker after authenticating.

EOF
