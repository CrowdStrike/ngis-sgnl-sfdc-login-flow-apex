# ngis-sgnl-sfdc-login-flow-apex

A Salesforce Login Flow, implemented in Apex and Visualforce, that asks SGNL which session-based permission sets a user may activate, lets the user pick from them at login, re-validates the selection with SGNL, and activates the approved permission sets for that session only.

SGNL is reached through the CrowdStrike access API using Falcon OAuth2 client credentials.

---

## Overview

Salesforce Screen Flows are the out-of-the-box tool for Login Flows, but they get painful once you need callouts and conditional logic. This project uses an Apex controller and a Visualforce page instead, while still plugging into Salesforce's native Login Flow mechanism.

### What it does

1. **Optional pre-login check.** If enabled, evaluates a configured SGNL action (default `login`). On deny, or if SGNL can't be reached, the user sees a denial message and is signed out.
2. **Fetches available permission sets.** Calls SGNL with `action: listPermissionSets`. SGNL returns the Salesforce Permission Set Ids the user is authorized to assume.
3. **Filters to what can actually be activated.** Keeps only session-based permission sets (Session Activation Required) that are already assigned to the user, and shows them as a checkbox list.
4. **Validates the selection.** On submit, calls SGNL again with one `action: assumePermissionSet` query per selected Id. Activation proceeds only if SGNL returns exactly one Allow per query.
5. **Activates session permissions.** Inserts `SessionPermSetActivation` records against the user's root session. They apply to that session only. Salesforce deletes the records some time after the session ends, not right away.
6. **Completes the login.** Returns the `PageReference` from `Auth.SessionManagement.finishLoginFlow()` so Salesforce routes the user to their destination.

---

## Key components

| File | Purpose |
|------|---------|
| `classes/LoginFlowController.cls` | Login flow logic: pre-login check, list, filter, validate, activate |
| `classes/SgnlClient.cls` | Typed client for `POST /v1/providers`; decision matching |
| `classes/LoginFlowConfig.cls` | Reads optional overrides from `LoginFlow_Config__mdt.Default`; every value has a default |
| `classes/LoginFlowAdminController.cls` | Backs the read-only admin page and Test Connection |
| `classes/*Test.cls` | Unit tests with `HttpCalloutMock` |
| `pages/LoginFlowPermSets.page` | SLDS checkbox UI and denial state |
| `lwc/loginFlowAdmin/` | Admin page: effective config, Test Connection, link to Setup |
| `permissionsets/NGIS_SGNL_Login_Flow_User` | Required by every user who goes through the flow |
| `permissionsets/NGIS_SGNL_Login_Flow_Admin` | Admin app/tab and Test Connection |
| `objects/LoginFlow_Config__mdt/` | Custom Metadata Type for optional settings |
| `sgnl-credentials/` | Named Credential `NGIS_SGNL_Access` and External Credential `NGIS_SGNL_Falcon_OAuth` (separate package directory, see [Deployment](#deployment)) |
| `scripts/bootstrap.sh` | One-shot tenant setup |

---

## Prerequisites

**Tools**

- Salesforce CLI: `npm install --global @salesforce/cli`
- `jq`
- A target org (sandbox, scratch org, or Developer Edition), authenticated: `sf org login web --alias <name>`

**CrowdStrike / SGNL**

- A Falcon API client (client id and secret) with the `sgnl-access:read` scope.
- That API client mapped to your SGNL provider.
- An SGNL provider hook whose application Id path is `{$.context.routingKey}`, with two integration assignments for this org's Protected System:
  - application Id `<orgid>_search`, routed to search, with a transform that returns `{ "decision": "allow", "permissionSetIds": [...] }`;
  - application Id `<orgid>_evaluate`, routed to access evaluation.

  `<orgid>` is the 15-character Salesforce Org Id. The flow derives both routing keys from the running org, and the admin page and the bootstrap script print them, so there's nothing to type in Salesforce.
- Policies for the `listPermissionSets`, `assumePermissionSet` and (if used) pre-login actions.

**Salesforce**

- The permission sets you want users to activate must have **Session Activation Required** checked and must be **assigned** to those users. The flow only activates assigned session-based sets.
- Every user who goes through the flow needs the `NGIS_SGNL_Login_Flow_User` permission set. Without it, the user gets **Insufficient Privileges** right after authenticating and can't log in. The bootstrap script assigns it to the profile's active users when it runs; assign it yourself to users added later (see [Rollout](#rollout)).

---

## Deployment

The Named Credential and External Credential live in a separate package directory, `sgnl-credentials/`, with US-1 hosts (`access.crowdstrike.com`, `api.crowdstrike.com`) as defaults. Routine deploys of `force-app` therefore never reset a non-US-1 org's hosts. Deploy `sgnl-credentials` on first install or when you change cloud.

| Falcon cloud | Named Credential URL | External Credential token URL |
|--------------|----------------------|-------------------------------|
| US-1 | `https://access.crowdstrike.com` | `https://api.crowdstrike.com/oauth2/token` |
| US-2 | `https://access.us-2.crowdstrike.com` | `https://api.us-2.crowdstrike.com/oauth2/token` |
| EU-1 | `https://access.eu-1.crowdstrike.com` | `https://api.eu-1.crowdstrike.com/oauth2/token` |

### Bootstrap script (recommended)

```bash
./scripts/bootstrap.sh
```

It prompts for:

1. **Org alias**: the `sf` alias you authenticated
2. **Falcon cloud**: US-1, US-2 or EU-1, or another `access.<cloud>.crowdstrike.com` host. The token host `api.<cloud>.crowdstrike.com` is derived from it. One cloud per org.
3. **Falcon client id and secret**: optional; leave blank to set them in Setup later. The script first lists what the API client needs: the `sgnl-access:read` scope, one client per org, and a mapping to your SGNL provider.
4. **Profile name**: the profile whose users should go through the login flow
5. **Pre-login check**: optional

Then it deploys `force-app` and `sgnl-credentials`, creates the `LoginFlow_Config.Default` record with every setting filled in (see [Configuration](#configuration)), sets the client id and secret on the `NGIS_SGNL_Principal` principal, assigns `NGIS_SGNL_Login_Flow_Admin` to you and `NGIS_SGNL_Login_Flow_User` to every active user on the profile, and prints the two SGNL provider hook application Ids for this org. If you supplied credentials, it then offers to run Test Connection and shows the result. It also prints the Setup steps to attach the Login Flow to the profile, which is manual. Attach it only after Test Connection succeeds.

The script is safe to re-run. Existing assignments are left alone; credentials are updated in place; an existing config record is kept unless you choose to overwrite its pre-login fields.

### Manual deployment

```bash
# First install (or after changing cloud): edit the two URLs in sgnl-credentials/ first if not on US-1
sf project deploy start --source-dir force-app --source-dir sgnl-credentials --target-org <org> --wait 30

# Later code-only deploys
sf project deploy start --source-dir force-app --target-org <org> --wait 30
```

Then, in Setup:

1. **Named Credentials → External Credentials → NGIS SGNL Falcon OAuth → Principals → NGIS_SGNL_Principal → Edit**: enter the Falcon client id and secret.
2. **Permission Sets**: assign `NGIS SGNL Login Flow User` to every user who will go through the flow, and `NGIS SGNL Login Flow Admin` to admins.
3. **Identity → Login Flows → New**: Flow Type **Visualforce Page**, page `LoginFlowPermSets`, then assign it to the profile.

---

## Configuration

Settings live on the `LoginFlow_Config.Default` record, which the bootstrap script creates with every value filled in. A blank field, or no record at all, uses the default below. The admin page shows those values as "Not set" with the default, and each field's help text in Setup gives its default.

To change a value: **Setup → Custom Metadata Types → Login Flow Config → Manage Records**, then create or edit the record named `Default`. Editing needs the **Customize Application** permission. On the admin page, **Edit in Setup** opens the record's edit page, or **Create in Setup** opens a new record when there isn't one yet.

| Field | Default | What it does |
|-------|---------|--------------|
| **Pre-Login Check Enabled** | off | Evaluate the pre-login action before showing the picker |
| **Pre-Login Action** | `login` | SGNL action for the pre-login check |
| **Denial Message** | generic message | Shown when the pre-login check denies |
| **Denial Auto Logout Seconds** | 10 (1 to 600) | How long the denial message shows before sign-out |

The routing keys aren't configurable. They're always the running org's 15-character Id plus `_search` or `_evaluate`, so a refreshed sandbox sends its own values and can't reach production's Protected System.

### Admin page

Open **Continuous Identity Admin** from the App Launcher (requires `NGIS SGNL Login Flow Admin`). It shows the effective configuration, and the application Id path and two application Ids to enter on the SGNL provider hook for this org. Its **Test Connection** button makes a live `listPermissionSets` call as you and shows the raw response and a hint on failure.

---

## Pre-login check

When enabled, the flow evaluates the pre-login action before the picker renders:

- **Allow**: continue to the permission set picker.
- **Deny, or any error** (SGNL unreachable, token failure, malformed response): fail closed. The page shows the denial message and signs the user out after the configured delay.

Because errors deny, an SGNL or credential outage locks out every user on the profile while the check is on. Turn the check off in the config record if you need availability during an outage.

---

## Rollout

- Never attach the Login Flow to the profile of your only administrator until you've tested it with another user.
- **Assign `NGIS SGNL Login Flow User` to users added to the profile later, before they log in.** Without it they get Insufficient Privileges right after authenticating and can't log in at all, with the pre-login check on or off. The profile's Login Flow points at the `LoginFlowPermSets` page but doesn't grant access to it; only the permission set does.
- Test with a non-admin user on the profile: log out, log back in, and confirm the picker appears and activation works.

---

## Running tests

```bash
sf apex run test \
  --class-names SgnlClientTest \
  --class-names LoginFlowControllerTest \
  --class-names LoginFlowConfigTest \
  --class-names LoginFlowAdminControllerTest \
  --code-coverage --result-format human --wait 10 \
  --target-org <org>
```

Or validate a deploy with tests, without committing it:

```bash
sf project deploy validate --source-dir force-app --source-dir sgnl-credentials --target-org <org> \
  --test-level RunSpecifiedTests \
  --tests SgnlClientTest --tests LoginFlowControllerTest --tests LoginFlowConfigTest --tests LoginFlowAdminControllerTest
```

---

## Troubleshooting

**The Login Flow screen never appears**
- Confirm the Login Flow is assigned to the user's profile, and the VF page is `LoginFlowPermSets`.
- Make sure the user isn't going through another Login Flow.

**Insufficient Privileges right after login**
- The user doesn't have `NGIS SGNL Login Flow User`, which grants access to the `LoginFlowPermSets` page. Assign it, then have the user log in again. This usually affects users added to the profile after the bootstrap script ran, and happens with the pre-login check on or off.

**"Unable to load permission sets right now" on the login page, or Test Connection fails with HTTP 0**
- The callout failed before reaching SGNL. Check the client id and secret on `NGIS_SGNL_Principal`, that the token URL (`api.<cloud>`) and Named Credential URL (`access.<cloud>`) match your Falcon cloud, and that the user has `NGIS SGNL Login Flow User` (or, for Test Connection, `NGIS SGNL Login Flow Admin`).

**Test Connection returns HTTP 401 or 403**
- The authorizer rejected the token. Check the Falcon API client has `sgnl-access:read` and is mapped to your SGNL provider.

**"Access denied by SGNL" on page load**
- SGNL doesn't recognize the user, or no policy allows `listPermissionSets`. Verify the Salesforce username matches the principal SGNL expects, and that the provider hook's application Ids match the ones on the admin page.

**The picker is skipped even though SGNL returns permission sets**
- The flow only offers session-based permission sets assigned to the user. Check **Session Activation Required** and the user's assignments.

**Every user on the profile is denied**
- With the pre-login check on, any SGNL or credential failure denies. Turn the check off in the config record, then fix connectivity using Test Connection.

**"Your permitted access has changed" after submitting**
- SGNL denied at least one selected permission set at submit time, or an assignment was removed while the page was open. Nothing was activated. If SGNL listed the set but denies `assumePermissionSet`, check that the two policies agree.

**"Your selection was approved but could not be activated"**
- The `SessionPermSetActivation` insert failed. Check the debug log for `SGNL login flow activate failed`. Make sure the Login Flow is on the primary login policy.

**Continuous Identity Admin is missing from App Launcher**
- Assign `NGIS SGNL Login Flow Admin`. It grants the app and tab visibility.

---

## Design notes

For the reasoning behind the non-obvious parts (Login Flow quirks, session activation, view state), see [`docs/DESIGN.md`](docs/DESIGN.md).

---

## License

MIT. See [LICENSE](LICENSE).
