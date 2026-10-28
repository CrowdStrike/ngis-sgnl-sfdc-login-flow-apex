# Design Notes

Why the code is shaped the way it is. The README covers what and how; this covers why. Read it before making non-obvious changes to `LoginFlowController.cls`, `SgnlClient.cls`, `LoginFlowPermSets.page`, or the credential metadata.

---

## The Login Flow contract

A Salesforce Login Flow is a Visualforce page (or Screen Flow) that Salesforce injects between successful authentication and the user landing on their destination. Some non-obvious behaviors shape this codebase:

- The flow runs **as the authenticated user**. Every query and callout uses their permissions unless code explicitly runs in system mode.
- The flow page is served from **`login.salesforce.com`** in some org configurations, not the org's My Domain, so relative redirects like `/home/home.jsp` can resolve to the wrong host.
- Salesforce expects the controller to call **`Auth.SessionManagement.finishLoginFlow()`** to complete the flow. The returned `PageReference` routes the user to the right destination, including the session handoff from `login.salesforce.com` to My Domain. Manual redirects don't trigger that handoff.
- The `retURL` parameter is **not a safe destination**. It can point to a nested `contentDoor` URL that resolves back to `/apex/LoginFlowPermSets`, creating a loop.

**Dead ends already ruled out:**
- Redirecting to `startURL`: usually blank in this flow.
- Redirecting to `retURL`: creates the loop above.
- Building `frontdoor.jsp?sid=...&retURL=...` by hand: reprompts for password, because the session isn't fully established yet.
- `URL.getOrgDomainUrl().toExternalForm() + '/home/home.jsp'`: lands on the org with the wrong session cookie ("To access this page, first finish logging in").

Only `finishLoginFlow()` handles all of this.

---

## Authentication: Falcon OAuth2 client credentials

The flow calls SGNL through the CrowdStrike access API: `https://access.<cloud>.crowdstrike.com/v1/providers`, behind the CrowdStrike authorizer. The authorizer accepts Falcon OAuth2 access tokens issued by `https://api.<cloud>.crowdstrike.com/oauth2/token` for an API client with the `sgnl-access:read` scope, and resolves the token to the SGNL provider the client is mapped to.

Salesforce handles the token entirely:

- `NGIS_SGNL_Falcon_OAuth` (External Credential) uses protocol `Oauth`, variant `ClientCredentialsClientSecret`. That variant sends `client_id`/`client_secret` in the token request body, which is what Falcon expects. (`ClientCredentialsClientSecretBasic` would send them in an Authorization header instead.)
- Salesforce fetches, caches and refreshes the token. Apex only does `callout:NGIS_SGNL_Access/v1/providers`.
- The client id and secret live on the `NGIS_SGNL_Principal` Named Principal. Metadata API can't carry them, which keeps them out of source; the bootstrap script sets them through the Connect API (`/services/data/vXX.X/named-credentials/credential/`).

### Why the credentials are in their own package directory

The access and token hosts differ per Falcon cloud. If the Named Credential and External Credential lived in `force-app`, every routine `sf project deploy start --source-dir force-app` would reset a non-US-1 org back to US-1 hosts. `sgnl-credentials/` is a separate, non-default package directory with US-1 defaults. It's deployed on first install or a cloud change; the bootstrap script patches the hosts into a temporary copy before deploying.

An earlier version tried to handle this with a `.forceignore` entry plus an in-place patch. Combined, those meant the patched Named Credential never deployed at all.

### What the token does and doesn't prove

The token identifies the Salesforce org (one API client per org), not the user. SGNL does not compare `principal.id` in the body to anything in the token. So any code in the org that can make the callout can ask SGNL about any principal mapped to the provider. This is the same model as the CrowdStrike GitHub policy action, which also asserts the principal in the body. The exposure is bounded by:

- Only users with External Credential principal access can make the callout (the `NGIS_SGNL_*` permission sets).
- Running arbitrary callouts needs Author Apex.
- The API client's scope is read-only (`sgnl-access:read`).

**Why credential access can't come from a session permission set activated by this flow:** the callouts in `init()` happen before anything is activated. Credential access must come from a permanently assigned permission set (`NGIS_SGNL_Login_Flow_User`).

---

## SGNL request and response shapes

Both calls are `POST /v1/providers` with `context: { org, routingKey }`. `org` is the plain 15-character Org Id. The tenant's SGNL provider hook reads `{$.context.routingKey}`: one integration assignment matches `<orgid>_search` and routes to search, another matches `<orgid>_evaluate` and routes to access evaluation. No SGNL code knows the `_search`/`_evaluate` suffixes; they're tenant configuration. SGNL also copies `context` keys into policy fields, which is why each evaluation decision echoes `"org"`.

### Why there's a separate routing key

`/v1/providers` is a single URL, so the request body has to tell SGNL which route to use. Each integration assignment matches one value read from one JSON path, carries one route, and its application Id must be unique within the provider hook. Each org needs two routes, so it needs two assignments and two distinct values. Matching on the plain Org Id would give one route per org, and matching on a bare `search`/`evaluate` field would give one org per provider hook. So the matched value has to combine both: `<orgid>_search` / `<orgid>_evaluate`.

That value lives in its own key, `routingKey`, so `org` stays the real Org Id. An earlier version packed the suffix into `org` itself, so policies and logs saw `00D..._evaluate` instead of the org.

The suffix is hidden from admins. `LoginFlowConfig` always derives both routing keys from the running org; there is no override. The admin page and the bootstrap script print the application Id path and the exact application Ids for the SGNL side. An earlier version had Org Id override fields on the config record; they were removed because the only thing an override could do was disagree with the provider hook, and a sandbox refresh copies config records, so a production override would have pointed a refreshed sandbox at production's Protected System.

The list response (`{ "decision": "allow", "permissionSetIds": [...] }`) is not an SGNL type. It comes from a custom transform template on the tenant's search route, which returns at most 1000 results and doesn't paginate. The evaluate response (`assumePermissionSet` and pre-login) is SGNL's `AccessEvaluationResponse`: `decisions[]` plus `principalId`, with `action` and `assetId` optional on each decision. `SgnlClient` deserializes both into typed classes; fields it doesn't model are ignored, and a type mismatch is wrapped as `SgnlException`.

### Decision matching

`SgnlClient.allAllowed()` returns true only if:

- there is exactly one decision per query (an earlier version accepted fewer decisions than queries, so one Allow could activate two permission sets);
- every `decision` is `Allow`, compared case-insensitively;
- any `action` or `assetId` a decision echoes back matches the query at the same index. Asset ids compare as `Id`, so 15- and 18-character forms match.

The list call compares `decision` to `allow` case-insensitively too, since its shape comes from tenant configuration.

A partial deny at submit activates nothing, by product decision. SGNL returns one decision per query in order, so a partial grant would be safe, but the list and submit calls are seconds apart, so a deny between them means the user's access changed. The message asks them to sign out and log in again to have it re-evaluated, or continue without activating.

---

## Error handling

Every SGNL path in the controller catches all exceptions: `SgnlException` (non-2xx, empty body, malformed JSON, wrapped `CalloutException`), plus anything unexpected. A raw Salesforce error page in the middle of login is never the right outcome.

| Path | On failure |
|------|------------|
| Pre-login check | Deny (fail closed) |
| `listPermissionSets` | Error banner; user can continue without permission sets |
| `assumePermissionSet` | Stay on the page with an error |
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

### Why the meta refresh is in `<body>`

VF doesn't give clean access to `<head>` from an `<apex:outputPanel rendered="{!denied}">`. Browsers honor the tag in `<body>`; the JavaScript timer is the safety net.

### The "in10 seconds" typo

VF strips inter-tag whitespace, so a label and an `<apex:outputText>` on separate lines render as `signed out in10 seconds`. Keep `You will be signed out in <apex:outputText value="{!denialAutoLogoutSeconds}" /> seconds.` on one line.

---

## Configuration: optional CMT overrides with derived defaults

Runtime settings live in `LoginFlow_Config__mdt.Default`; `LoginFlowConfig.cls` reads them with `LoginFlow_Config__mdt.getInstance('Default')` (no SOQL) and caches the result for the request.

Every field is optional. The pre-login check defaults to off, the action to `login`, the denial delay to 10 seconds (clamped to 1 to 600).

The routing keys are not configurable: they're always `UserInfo.getOrganizationId().left(15)` plus `_search` / `_evaluate`. A fresh org works with no record, and a sandbox refresh can't carry production's routing values over. See "Why there's a separate routing key" above.

An earlier version's fallbacks were a specific tenant's org id and hosts, which would have made a new customer org call SGNL with another org's context. There are no tenant values in code now.

The Named Credential name and API path are constants in `SgnlClient`, not configuration. Making them configurable let anyone who could edit the config point the login flow at a different Named Credential.

### Why CMT and not Custom Settings

- CMT records are deployable and appear in the Setup Audit Trail.
- CMT reads don't consume SOQL queries.
- CMT is package-friendly.

### Why there is no in-app save

An earlier version saved from the LWC through `Metadata.Operations.enqueueDeployment`, which needs **Modify Metadata** (close to full admin) on the admin permission set and is awkward from a managed package. Admins now edit the record in Setup's native Custom Metadata UI, which needs **Customize Application**, gives the audit trail for free, and needs no extra grants. The admin page is read-only, shows the effective values, and links to Setup.

### Seeding the record

The bootstrap script writes a `customMetadata/LoginFlow_Config.Default.md-meta.xml` into its temporary copy of the project, only when the operator enables the pre-login check. The file declares the `xsi`/`xsd` namespaces and types each value (`xsd:boolean`, `xsd:string`). Fields omitted from the file are left unchanged on update, so it doesn't overwrite other edits made in Setup.

Don't commit a CMT record to source: it would overwrite Setup edits on every deploy. An earlier hand-written record also failed with an opaque `UNKNOWN_EXCEPTION`, probably from missing namespaces or value types. If you need a committed record, create it in Setup and retrieve it with `sf project retrieve start --metadata CustomMetadata:LoginFlow_Config.Default`.

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

A login flow runs in a child session, and inserting against a child session throws `FIELD_INTEGRITY_EXCEPTION, Session permission set cannot be activated for a child session`. The controller uses `Auth.SessionManagement.getCurrentSession()` and takes `ParentId`, or `SessionId` when there's no parent, the same pattern Salesforce's own example uses.

An earlier version queried the user's most recent root `AuthSession`. With concurrent sessions (another browser or device), that could activate permission sets on the wrong session. There is no fallback to that query.

### Duplicates throw `DUPLICATE_VALUE`

If the user re-runs the flow, previously activated sets are still on the session, and inserting them again fails. The controller queries existing activations for the session and skips them. `SessionPermSetActivation` isn't upsertable.

### Callouts before DML

Apex rejects a callout after uncommitted DML in the same transaction. `activate()` calls SGNL first and inserts only after approval. Keep it that way.

### Activation is not the only way in

Salesforce lets a user activate their own assigned session permission sets with the `activateSessionPermSet` standard action (REST API) and the Flow "Activate Session-Based Permission Set" action. SGNL gates this login flow, not those paths. Mitigate by removing API Enabled from users in scope and auditing flows that use the action.

---

## Visualforce view state and controller lifecycle

### Why the config is resolved in the constructor

The constructor sets `denialAutoLogoutSeconds`, which the page reads on every render, including postbacks where `init()` doesn't run.

### Offered ids are pinned in view state

`init()` records the ids it offered in a private `offeredIds` set, and `PermSetOption.psId` has a private setter. `activate()` rejects any selection not in `offeredIds`. View state is encrypted and signed by Salesforce, so this is belt-and-braces against a tampered postback.

### Why "Continue without activating" has `immediate="true"`

`immediate="true"` skips value binding on postback, so the skip action runs even if the checkbox state is bad. "Accept and Continue" needs the checkbox state, so it omits `immediate`.

---

## SLDS checkbox pattern: the `id`/`for` link

SLDS hides the real `<input>` and uses a `<label>` with `<span class="slds-checkbox_faux">` as the click target. The label only toggles the input if its `for` matches the input's id. VF mangles ids (`j_id0:j_id2:0:chk`), so the page uses `$Component`:

```html
<apex:inputCheckbox id="chk" value="{!opt.selected}" />
<label for="{!$Component.chk}" class="slds-checkbox__label">
    <span class="slds-checkbox_faux"></span>
    ...
</label>
```

Without it, clicking the visible checkbox does nothing.

---

## Admin UI (LWC)

- Read-only: effective values (with defaults applied), whether a `Default` record exists, and an **Edit in Setup** link.
- **Test Connection** fires a live `listPermissionSets` call as the admin. It never throws: callout failures (including token-fetch failures) return `statusCode: 0` with the exception text and a hint; 401/403 get a hint about the API client's scope and provider mapping. It tests the saved configuration, not anything typed on the page.
- The admin needs External Credential principal access because Test Connection calls out as them; `NGIS_SGNL_Login_Flow_Admin` grants it along with the app and tab.

### Tab visibility trap

A newly deployed `CustomTab` is hidden from every profile until a profile or permission set grants it. It then doesn't appear in App Launcher, the App Manager navigation picker, or `TabDefinition`. `SELECT Id FROM TabDefinition WHERE Name='Login_Flow_Admin'` returning zero rows means visibility is the problem. `NGIS_SGNL_Login_Flow_Admin` grants the tab and the app.

---

## Bootstrap script design

- **Never touches the working tree.** It copies the project into `mktemp -d`, patches the hosts and optional CMT record there, and deploys from the copy.
- **Hosts are allowlisted.** The access host must match `^access\.([a-z0-9-]+\.)*crowdstrike\.(com|red|black)$` (the same check as the CrowdStrike GitHub policy action); the token host is `api.` plus the rest. Validated hosts are safe to substitute with `sed`.
- **The secret never appears on a command line.** It's read with `read -rs`, passed to `jq` through the environment, written to a mode-600 file (`umask 077`), and sent with `sf api request rest --body @file`. POST creates the principal's credentials; PUT updates them on re-runs.
- **Lockout ordering.** The script never attaches the Login Flow. `LoginFlow` isn't available through the REST or Tooling API ("sObject type 'LoginFlow' is not supported"), so attaching it is a Setup step the script prints last, after the user permission set is assigned and after Test Connection. If the assignment fails, the script stops and says not to attach the flow.
- **Paged assignment.** Users are assigned in pages of 5,000, ordered by Id, one anonymous Apex run per page, so large profiles stay under the per-transaction limits (10,000 DML rows, 50,000 query rows). Each page resumes after the previous page's last Id, so users whose assignment keeps failing (for example a license mismatch) can't stall the loop. If a page's result can't be read, the script stops without creating the flow.
- **Idempotent.** Existing assignments are left alone; credentials are updated.
- **`jq` is required** for parsing `sf --json` output reliably.

---

## Test coverage limits

The `HttpCalloutMock` tests cover request shape, every SGNL failure mode, decision matching, the eligibility filter, view-state checks, the denied guards and the insert-failure path. They can't cover:

- A successful `SessionPermSetActivation` insert: no `AuthSession` can exist in `@IsTest`.
- `getCurrentSession()`: throws "Current session unavailable" in tests, hence `sessionIdOverride`.
- `finishLoginFlow()`: returns null outside a real login flow, so tests assert on controller state, not redirects.
- The VF render, the LWC (no Jest setup yet) and the real token exchange.

Verify these in a sandbox with the Login Flow assigned to a test profile.

### To verify in a sandbox

These are documented behaviors we haven't yet observed end to end:

- Salesforce's token exchange accepts the Falcon token endpoint's HTTP 201 response.
- How a token-fetch failure surfaces in Apex (exception vs 401).
- Redeploying the External Credential keeps the principal's stored secret.
- `getCurrentSession()` returns a `ParentId` inside the VF login flow, and the insert against it succeeds.
- The behavior of `activateSessionPermSet` for an API-enabled standard user (for the threat model).
- The bootstrap script's generated CMT record deploys cleanly.
