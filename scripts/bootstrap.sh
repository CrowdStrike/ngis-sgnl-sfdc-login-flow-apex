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

prompt "Salesforce CLI org alias: "
read -r ORG_ALIAS
[[ -z "$ORG_ALIAS" ]] && die "Org alias is required."

info "Checking authentication for '$ORG_ALIAS'..."
IDENTITY_JSON="$(sf org display user --target-org "$ORG_ALIAS" --json 2>/dev/null)" \
  || die "Not authenticated. Run: sf org login web --alias $ORG_ALIAS"
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
    ;;
  *) die "Invalid choice '$CLOUD_CHOICE'." ;;
esac
[[ "$ACCESS_HOST" =~ $ACCESS_HOST_PATTERN ]] \
  || die "Invalid access host '$ACCESS_HOST'. Expected access.crowdstrike.com or access.<cloud>.crowdstrike.com."
TOKEN_HOST="api.${ACCESS_HOST#access.}"
info "API endpoint:   https://$ACCESS_HOST"
info "Token endpoint: https://$TOKEN_HOST/oauth2/token"

prompt "Falcon client id (leave blank to set credentials later in Setup): "
read -r CLIENT_ID
CLIENT_SECRET=""
if [[ -n "$CLIENT_ID" ]]; then
  prompt "Falcon client secret: "
  read -rs CLIENT_SECRET
  echo
  [[ -z "$CLIENT_SECRET" ]] && die "Client secret is required when a client id is given."
fi

heading "Login Flow assignment"

prompt "Profile whose users will go through the Login Flow (e.g. Standard User): "
read -r PROFILE_NAME
[[ -z "$PROFILE_NAME" ]] && die "Profile name is required."

heading "Pre-login evaluation"

prompt "Enable pre-login check now? [y/N]: "
read -r PRELOGIN_ANSWER
PRELOGIN_ENABLED=false
PRELOGIN_ACTION=login
if [[ "$PRELOGIN_ANSWER" =~ ^[Yy]$ ]]; then
  PRELOGIN_ENABLED=true
  prompt "Pre-login action name [default: login]: "
  read -r PRELOGIN_ACTION
  PRELOGIN_ACTION="${PRELOGIN_ACTION:-login}"
  [[ "$PRELOGIN_ACTION" =~ ^[A-Za-z0-9_.:-]+$ ]] \
    || die "Pre-login action may only contain letters, digits, '_', '.', ':' and '-'."
fi

# -----------------------------------------------------------------------------
# Look up the profile before changing anything
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

# Pre-login settings go into the LoginFlow_Config.Default record. Without a
# record every value uses its built-in default, so only write one if needed.
if [[ "$PRELOGIN_ENABLED" == true ]]; then
  EXISTING_CFG="$(sf data query --target-org "$ORG_ALIAS" \
    --query "SELECT DeveloperName FROM LoginFlow_Config__mdt WHERE DeveloperName='Default'" \
    --json 2>/dev/null | jq -r '.result.totalSize // 0')"
  WRITE_CFG=true
  if [[ "$EXISTING_CFG" == "1" ]]; then
    prompt "A Default config record already exists. Overwrite its pre-login fields? [y/N]: "
    read -r OVERWRITE
    [[ "$OVERWRITE" =~ ^[Yy]$ ]] || WRITE_CFG=false
  fi
  if [[ "$WRITE_CFG" == true ]]; then
    CMT_DIR="$STAGE_DIR/force-app/main/default/customMetadata"
    mkdir -p "$CMT_DIR"
    # Only the fields set here are written; other fields keep their values.
    cat > "$CMT_DIR/LoginFlow_Config.Default.md-meta.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <label>Default</label>
    <protected>false</protected>
    <values>
        <field>Pre_Login_Check_Enabled__c</field>
        <value xsi:type="xsd:boolean">true</value>
    </values>
    <values>
        <field>Pre_Login_Action__c</field>
        <value xsi:type="xsd:string">$PRELOGIN_ACTION</value>
    </values>
</CustomMetadata>
XML
    ok "Staged LoginFlow_Config.Default with pre-login enabled (action: $PRELOGIN_ACTION)"
  else
    info "Leaving the existing config record unchanged."
  fi
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
# flow is attached; without it the SGNL callout fails (and with the pre-login
# check on, they are denied).
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
# Done
# -----------------------------------------------------------------------------
heading "Done"

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

  2. Open the admin page and click "Test Connection". It should return
     HTTP 200 and a JSON body listing your permission sets.
     ${c_dim}sf org open --target-org $ORG_ALIAS --path /lightning/n/Login_Flow_Admin${c_reset}

  3. Only after Test Connection succeeds, attach the Login Flow:
     Setup → Identity → Login Flows → New. Flow Type "Visualforce Page",
     page LoginFlowPermSets, profile '$PROFILE_NAME'. Keep an admin on a
     profile without the flow.

  4. Users added to '$PROFILE_NAME' later need the $USER_PERMSET
     permission set, or the flow can't call SGNL for them.

  5. Test the flow: log in with a user on '$PROFILE_NAME'. They should see
     the permission set picker after authenticating.

EOF
