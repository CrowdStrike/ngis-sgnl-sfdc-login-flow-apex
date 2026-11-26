# Design Notes

Why the code is shaped the way it is. The README covers what and how; this covers why. Read it before making non-obvious changes to `LoginFlowController.cls`, `SgnlClient.cls`, `LoginFlowPermSets.page`, or the credential metadata.

---

## The Login Flow contract

A Salesforce Login Flow is a Visualforce page (or Screen Flow) that Salesforce injects between successful authentication and the user landing on their destination. Some non-obvious behaviors shape this codebase:

- The flow runs **as the authenticated user**. Every query and callout uses their permissions unless code explicitly runs in system mode.
- The flow page is served from **`login.salesforce.com`** in some org configurations, not the org's My Domain, so relative redirects like `/home/home.jsp` can resolve to the wrong host.
- Salesforce expects the controller to call **`Auth.SessionManagement.finishLoginFlow()`** to complete the flow. The returned `PageReference` routes the user to the right destination, including the session handoff from `login.salesforce.com` to My Domain. Manual redirects don't trigger that handoff.
- The `retURL` parameter is **not a safe destination**. It can point to a nested `contentDoor` URL that resolves back to `/apex/LoginFlowPermSets`, creating a loop.

---

## Authentication: Falcon OAuth2 client credentials

The flow calls SGNL through the CrowdStrike access API: `https://access.<cloud>.crowdstrike.com/v1/providers`, behind the CrowdStrike authorizer. The authorizer accepts Falcon OAuth2 access tokens issued by `https://api.<cloud>.crowdstrike.com/oauth2/token` for an API client with the `sgnl-access:read` scope, and resolves the token to the SGNL provider the client is mapped to.

Salesforce handles the token entirely:

- `NGIS_SGNL_Falcon_OAuth` (External Credential) uses protocol `Oauth`, variant `ClientCredentialsClientSecret`. That variant sends `client_id`/`client_secret` in the token request body, which is what Falcon expects. (`ClientCredentialsClientSecretBasic` would send them in an Authorization header instead.)
- Salesforce fetches, caches and refreshes the token. Apex only does `callout:NGIS_SGNL_Access/v1/providers`.
- The client id and secret live on the `NGIS_SGNL_Principal` Named Principal. Metadata API can't carry them, which keeps them out of source; the bootstrap script sets them through the Connect API (`/services/data/vXX.X/named-credentials/credential/`).

### Why the credentials are in their own package directory

The access and token hosts differ per Falcon cloud. If the Named Credential and External Credential lived in `force-app`, every routine `sf project deploy start --source-dir force-app` would reset a non-US-1 org back to US-1 hosts. `sgnl-credentials/` is a separate, non-default package directory with US-1 defaults. It's deployed on first install or a cloud change; the bootstrap script patches the hosts into a temporary copy before deploying.

### What the token does and doesn't prove

The token identifies the Salesforce org (one API client per org), not the user. SGNL does not compare `principal.id` in the body to anything in the token. So any code in the org that can make the callout can ask SGNL about any principal mapped to the provider. This is the same model as the CrowdStrike GitHub policy action, which also asserts the principal in the body. The exposure is bounded by:

- Only users with External Credential principal access can make the callout: users on the flow's profile, and admins with `NGIS_SGNL_Login_Flow_Admin`.
- Running arbitrary callouts needs Author Apex.
- The API client's scope is read-only (`sgnl-access:read`).

**Why credential access can't come from a session permission set activated by this flow:** the callouts in `init()` happen before anything is activated. Credential access must be permanent: it's granted on the flow's profile (see "Flow user access" below).

---

## SGNL request and response shapes

Both calls are `POST /v1/providers` with `context: { org, routingKey }`. `org` is the plain 15-character Org Id. The tenant's SGNL provider hook reads `{$.context.routingKey}`: one integration assignment matches `<orgid>_search` and routes to search, another matches `<orgid>_evaluate` and routes to access evaluation. No SGNL code knows the `_search`/`_evaluate` suffixes; they're tenant configuration. SGNL also copies `context` keys into policy fields, which is why each evaluation decision echoes `"org"`.

### Why there's a separate routing key

`/v1/providers` is a single URL, so the request body has to tell SGNL which route to use. Each integration assignment matches one value read from one JSON path, carries one route, and its application Id must be unique within the provider hook. Each org needs two routes, so it needs two assignments and two distinct values. Matching on the plain Org Id would give one route per org, and matching on a bare `search`/`evaluate` field would give one org per provider hook. So the matched value has to combine both: `<orgid>_search` / `<orgid>_evaluate`.

That value lives in its own key, `routingKey`, so `org` stays the real Org Id in policies and logs.

The suffix is hidden from admins. `LoginFlowConfig` always derives both routing keys from the running org; there is no override. The admin page and the bootstrap script print the application Id path and the exact application Ids for the SGNL side. An override could only disagree with the provider hook, and a sandbox refresh copies config records, so a production override would point a refreshed sandbox at production's Protected System.

Both calls send the same action, `activate`, so one policy covers both and the picker offers exactly what submit would allow. The routing key, not the action, decides whether a request is a search or an evaluation.

Both responses are SGNL's own types. `SgnlClient` deserializes both into typed classes; fields it doesn't model are ignored, and a type mismatch is wrapped as `SgnlException`.

### Search

The search sends one `activate` query with no `assetId`. SGNL returns its asset search response: `decisions[]`, each with `assetId`, `action` and `decision`, plus `nextPageToken` and `principalId`. `SgnlClient.allowedAssetIds()` keeps a decision only if it is `Allow` (case-insensitive), its `action` is `activate` or absent, and its `assetId` isn't blank. The `assetId` is the permission set Id.

The provider route returns one page of up to 1000 allowed permission sets and doesn't take paging parameters. The flow reads that page only; when `nextPageToken` is set, it offers what it read and logs `SGNL login flow search returned more than one page of permission sets; offering the first page.`

The picker's options and the list of offered ids live in view state, which is capped at 170 KB. The picker therefore holds at most 600 options, about 100 to 120 KB at roughly 150 to 200 bytes an option. If more are eligible, the flow logs `SGNL login flow: N permission sets are eligible, but the picker holds 600 because of the Visualforce view state limit.`

### Submit batches

SGNL accepts 1 to 20 queries per evaluation, so submit sends the selection in batches of 20, one after another. Approval is all or nothing: the first batch that isn't all Allow, or any failure, stops the loop and nothing is activated. Before each batch, the flow checks the callouts used and the time spent so far; if another batch could run past the callout limit (100 per transaction) or the callout time limit (110 of the transaction's 120 seconds), it stops, logs the reason, and shows "Unable to verify your selection" instead.

### Picker pages

When more than 10 permission sets are offered, the picker shows 10 at a time with Previous and Next, and a status line with the page and how many permission sets are selected. Paging happens in the browser: every option is on the page, rows on other pages are hidden, and their checkboxes are still submitted.

### Counts in the debug log

Each page load logs how many permission sets SGNL allowed and how many are offered (`SGNL login flow: SGNL allowed N permission sets; M are offered.`). Each submit logs how many were selected. A large gap or a large count suggests a policy that's broader than it needs to be.

### Decision matching

`SgnlClient.allAllowed()` returns true only if:

- there is exactly one decision per query, so one Allow can't activate two permission sets;
- every `decision` is `Allow`, compared case-insensitively;
- any `action` or `assetId` a decision echoes back matches the query at the same index. Asset ids compare as `Id`, so 15- and 18-character forms match.

Submit applies it to each batch.

A partial deny at submit activates nothing, by product decision. SGNL returns one decision per query in order, so a partial grant would be safe, but the search and submit calls are seconds apart, so a deny between them means the user's access changed. The message asks them to sign out and log in again to have it re-evaluated, or continue without activating.

---

## Error handling

Every SGNL path in the controller catches all exceptions: `SgnlException` (non-2xx, empty body, malformed JSON, wrapped `CalloutException`), plus anything unexpected. A raw Salesforce error page in the middle of login is never the right outcome.

| Path | On failure |
|------|------------|
| Pre-login check | Deny (fail closed) |
| Search (`activate`, no asset) | Error banner; user can continue without permission sets |
| Submit (`activate` per set) | Stay on the page with an error |
| `SessionPermSetActivation` insert | Stay on the page with an error |

A list failure deliberately doesn't deny: it means the user logs in with least privilege. Use the pre-login check if SGNL availability should gate login itself.

Failures are logged with `System.debug(LoggingLevel.ERROR, 'SGNL login flow <step> failed: ...')`.

---

## The pre-login denial flow

### Why we don't call `finishLoginFlow()` on deny

`finishLoginFlow()` commits the session, which is exactly what we don't want on deny. The controller sets `denied = true` and returns `null`, keeping the user on the page. The page signs the user out three ways:

1. `<meta http-equiv="refresh" content="{!denialAutoLogoutSeconds};url=/secur/logout.jsp" />` in the body
2. A JavaScript `setTimeout` fallback in case the meta refresh is stripped
3. A "Sign out now" button

The session sits in Login-Flow limbo for the redirect window (default 10 seconds, max 600). The denied state renders no form, and `activate()`/`skip()` return immediately when `denied` is set, so there's no way to complete the flow from that state.

---

## Configuration: optional CMT overrides with derived defaults

Runtime settings live in `LoginFlow_Config__mdt.Default`; `LoginFlowConfig.cls` reads them with `LoginFlow_Config__mdt.getInstance('Default')` (no SOQL) and caches the result for the request.

Every field is optional. The pre-login check defaults to off, the action to `login`, the denial delay to 10 seconds (clamped to 1 to 600).

The routing keys are not configurable: they're always `UserInfo.getOrganizationId().left(15)` plus `_search` / `_evaluate`. A fresh org works with no record, and a sandbox refresh can't carry production's routing values over. See "Why there's a separate routing key" above.

The Named Credential name and API path are constants in `SgnlClient`, not configuration, so anyone who can edit the config can't point the login flow at a different Named Credential.

### Why CMT and not Custom Settings

- CMT records are deployable and appear in the Setup Audit Trail.
- CMT reads don't consume SOQL queries.
- CMT is package-friendly.

### Why there is no in-app save

Saving from the LWC would need `Metadata.Operations.enqueueDeployment`, which needs **Modify Metadata** (close to full admin) on the admin permission set and is awkward from a managed package. Admins edit the record in Setup's native Custom Metadata UI instead, which needs **Customize Application**, gives the audit trail for free, and needs no extra grants. The admin page is read-only, shows the effective values, and links to Setup.

### Seeding the record

The bootstrap script writes a `customMetadata/LoginFlow_Config.Default.md-meta.xml` into its temporary copy of the project. When no `Default` record exists, the file sets all four fields, so the Setup edit form shows real values instead of blanks. The default denial message and delay in the script must match `LoginFlowConfig`. When a record exists, the script writes only the pre-login fields, and only if the operator asks it to. The file declares the `xsi`/`xsd` namespaces and types each value (`xsd:boolean`, `xsd:string`, `xsd:double`). Fields omitted from the file are left unchanged on update, so it doesn't overwrite other edits made in Setup.

The admin page shows the saved values. A field left blank on the record still falls back to its default, and the page shows it as `Not set (default: <value>)`; the field help text in Setup names the same default.

The type ships its own page layout. Without one, Salesforce generates a layout with only the standard fields, and the Setup edit form shows none of the settings. The settings come first. Salesforce requires Label, Name, Protected Component and Namespace Prefix on every custom metadata layout, so they sit last, in a section titled "Record name (keep it Default)". The flow reads only the record named `Default`, so a renamed record falls back to the defaults.

Don't commit a CMT record to source: it would overwrite Setup edits on every deploy. If you need a committed record, create it in Setup and retrieve it with `sf project retrieve start --metadata CustomMetadata:LoginFlow_Config.Default`.

---

## `SessionPermSetActivation` quirks

### Only assigned, session-based sets can be activated

SGNL can return any permission set id. The controller keeps only ids that are Permission Set ids, are session-based (`HasActivationRequired = true`) and are assigned to the running user, using one query:

```apex
SELECT PermissionSetId, PermissionSet.Label
FROM PermissionSetAssignment
WHERE AssigneeId = :UserInfo.getUserId()
AND PermissionSetId IN :ids
AND PermissionSet.HasActivationRequired = true
```

The same check runs again on submit, since assignments can change while the page is open.

### Why these run in system mode

Standard users can't read `PermissionSetAssignment` (needs View Setup, Assign Permission Sets or Manage Users) and can't create `SessionPermSetActivation` (no API create; access needs View Setup or Manage Session Permission Set Activations). Granting those to every user would widen exposure far more than the flow needs.

So the assignment query, the existing-activation query and the insert run in system mode, inside the controller's private `without sharing` inner class `Privileged`. That class is the only privileged code, always filters to the running user, and is only reached after the controller's own checks and, for the insert, SGNL's approval. `WITH SYSTEM_MODE` and `AccessLevel.SYSTEM_MODE` make the intent explicit for reviewers.

### The AuthSession must be the root session

A login flow runs in a child session, and inserting against a child session throws `FIELD_INTEGRITY_EXCEPTION, Session permission set cannot be activated for a child session`. The controller uses `Auth.SessionManagement.getCurrentSession()` and takes `ParentId`, or `SessionId` when there's no parent, the same pattern Salesforce's own example uses. Inside a VF Login Flow, the current session is a `Visualforce` session whose parent is the root `UI` session.

There is no fallback to the user's most recent root `AuthSession`: with concurrent sessions (another browser or device), that could activate permission sets on the wrong session.

### Duplicates throw `DUPLICATE_VALUE`

If the user re-runs the flow, previously activated sets are still on the session, and inserting them again fails. The controller queries existing activations for the session and skips them. `SessionPermSetActivation` isn't upsertable.

### Cleanup is asynchronous

An activation applies only to its session, but Salesforce deletes the `SessionPermSetActivation` record asynchronously, some time after the session ends. A leftover record doesn't mean the session is still alive; check `AuthSession`.

### Callouts before DML

Apex rejects a callout after uncommitted DML in the same transaction. `activate()` calls SGNL first and inserts only after approval. Keep it that way.

### Activation is not the only way in

Salesforce lets a user activate their own assigned session permission sets with the `activateSessionPermSet` standard action (REST API) and the Flow "Activate Session-Based Permission Set" action. SGNL gates this login flow, not those paths. Mitigate by removing API Enabled from users in scope and auditing flows that use the action.

---

## Offered ids are pinned in view state

`init()` records the ids it offered in a private `offeredIds` set, and `PermSetOption.psId` has a private setter. `activate()` rejects any selection not in `offeredIds`. View state is encrypted and signed by Salesforce, so this is belt-and-braces against a tampered postback.

---

## Admin UI (LWC)

- Read-only: the saved values (blank fields labeled with the default they fall back to), whether a `Default` record exists, and an **Edit in Setup** link to the record's edit form.
- A setup checklist: client credentials, SGNL provider hook, Test Connection, attaching the Login Flow. The credential status comes from `ConnectApi.NamedCredentials.getCredential()` for the `NGIS_SGNL_Principal` principal. If the status can't be read, for example because the admin lacks the permission it needs, the page shows Unknown and stays usable. Apex can't tell whether a profile has the Login Flow attached, so that step is instructions and a link only.
- **Test Connection** runs the login's permission set search as the admin. It never throws: callout failures (including token-fetch failures) return `statusCode: 0` with the exception text and a hint; 401/403 get a hint about the API client's scope and provider mapping. It tests the saved configuration, not anything typed on the page.
- The admin needs External Credential principal access because Test Connection calls out as them; `NGIS_SGNL_Login_Flow_Admin` grants it along with the app and tab.

---

## Flow user access

### Why access is granted on the profile

The Login Flow is attached per profile, but the profile's Login Flow setting only names the VF page; it grants nothing. A user also needs access to the `LoginFlowPermSets` page, the controller classes and the External Credential principal. Without page access they get Insufficient Privileges right after authenticating and can't log in, with the pre-login check on or off.

Those grants live on the same profile as the Login Flow, so they cover exactly the users who go through the flow, including users added to the profile later. A permission set would have to be assigned to each user, and anyone added afterwards would be locked out until an admin assigned it.

### How the bootstrap script grants it

- **Page and Apex class access:** a generated Profile file per chosen profile with `pageAccesses` and `classAccesses`, deployed with the rest of `force-app`. A Profile deploy changes only the elements in the file, so the profile's other settings are kept. Profile metadata uses API names, not display names (Standard User is `Standard`), so the script maps each chosen profile's Id to its name with `sf org list metadata --metadata-type Profile`.
- **External Credential principal access:** Profile metadata doesn't accept `externalCredentialPrincipalAccesses`, although Setup shows the grant on profiles. The script inserts it through the API as a `SetupEntityAccess` row on the permission set every profile owns (`IsOwnedByProfile = true`). `ExternalCredentialParameter` isn't queryable, so the script takes the principal's Id from the same grant on `NGIS_SGNL_Login_Flow_Admin`.
- **The Login Flow itself:** the profile's `loginFlows` element, in a separate deploy (see "Lockout ordering" below).

---

## Bootstrap script design

- **Never touches the working tree.** It copies the project into `mktemp -d`, patches the hosts and optional CMT record there, and deploys from the copy.
- **Hosts are allowlisted.** The access host must match `^access\.([a-z0-9-]+\.)*crowdstrike\.(com|red|black)$` (the same check as the CrowdStrike GitHub policy action); the token host is `api.` plus the rest. Validated hosts are safe to substitute with `sed`.
- **The secret never appears on a command line.** It's read with `read -rs`, passed to `jq` through the environment, written to a mode-600 file (`umask 077`), and sent with `sf api request rest --body @file`. POST creates the principal's credentials; PUT updates them on re-runs.
- **Lockout ordering.** The operator can choose several profiles, but not their own; the script handles each one separately. It attaches the Login Flow to a profile last, and only when that profile has all its access and the operator says yes for that profile. A failed Test Connection doesn't block the attach, but the script warns first: with the pre-login check on, every user on an attached profile is denied until SGNL is reachable; with it off, they log in without permission sets. A profile has at most one Login Flow, so the script retrieves each profile first. If it already has the SGNL flow it does nothing; if it has a different one, it asks before replacing it. `LoginFlow` isn't available through the REST or Tooling API, so the attach is a deploy of the profile's `loginFlows` element. The closing steps list which profiles have the flow, how to attach it to the rest, and which profiles still need credential access before the flow can be attached.
- **Test Connection from the script.** After the access grants, the script runs `LoginFlowAdminController.testConnection()` as anonymous Apex, so the result matches the admin page's button. It runs even when no credentials were entered on this run, so a re-run tests the credentials saved in the org. It runs as the operator, who now has the admin permission set and with it the credential access. It reads the result from `USER_DEBUG` lines, because `sf apex run` also echoes the source.
- **Idempotent.** Existing assignments are left alone; credentials are updated.
- **`jq` is required** for parsing `sf --json` output reliably.

---

## Test coverage limits

The `HttpCalloutMock` tests cover request shape, every SGNL failure mode, decision matching, the eligibility filter, view-state checks, the denied guards and the insert-failure path. They can't cover:

- A successful `SessionPermSetActivation` insert: no `AuthSession` can exist in `@IsTest`.
- `getCurrentSession()`: throws "Current session unavailable" in tests, hence `sessionIdOverride`.
- `finishLoginFlow()`: returns null outside a real login flow, so tests assert on controller state, not redirects.
- The VF render, the LWC and the real token exchange.

Verify these in a sandbox with the Login Flow assigned to a test profile.
