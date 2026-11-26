public with sharing class LoginFlowController {

    @TestVisible private static final String MSG_LIST_FAILED   = 'Unable to load permission sets right now. You can continue without them.';
    @TestVisible private static final String MSG_NO_SELECTION  = 'Please select at least one permission set, or click "Continue without activating".';
    // Shown on an SGNL deny at submit, or when the selection no longer
    // matches what was offered or assigned. Wording agreed with product.
    @TestVisible private static final String MSG_NOT_APPROVED  = 'Your permitted access has changed. Sign out and log in again to have it re-evaluated, or continue without activating.';
    @TestVisible private static final String MSG_VERIFY_FAILED = 'Unable to verify your selection right now. Please try again or continue without activating.';
    @TestVisible private static final String MSG_ACTIVATE_FAILED = 'Your selection was approved but could not be activated. Please try again or contact your administrator.';

    // Populated on page load from SGNL, filtered to what the user can activate
    public List<PermSetOption> availablePermSets { get; private set; }

    // Surfaced to the page for inline error display
    public String errorMessage { get; private set; }

    // Set to true when the pre-login check has denied access. The page uses
    // this to render the denial state (message + auto-redirect to logout).
    public Boolean denied { get; private set; }
    public String denialMessage { get; private set; }
    public Integer denialAutoLogoutSeconds { get; private set; }

    // Resolved once per request from LoginFlow_Config__mdt.Default
    @TestVisible private LoginFlowConfig cfg;

    // Ids offered on page load. activate() rejects anything else. Kept in
    // (encrypted, signed) view state across the postback.
    private Set<Id> offeredIds;

    // getCurrentSession() throws "Current session unavailable" in tests
    @TestVisible private static Id sessionIdOverride;

    // Most options the picker holds. The options and offeredIds live in view
    // state, which Visualforce caps at 170 KB.
    @TestVisible private static Integer maxPickerOptions = 600;

    public LoginFlowController() {
        this.cfg = LoginFlowConfig.getInstance();
        this.availablePermSets       = new List<PermSetOption>();
        this.offeredIds              = new Set<Id>();
        this.denied                  = false;
        this.denialAutoLogoutSeconds = cfg.denialAutoLogoutSecs;
    }

    // ---------------------------------------------------------------
    // Called by the VF page on load (invoked via action="{!init}")
    // ---------------------------------------------------------------
    public PageReference init() {
        // Optional pre-login evaluation. If enabled and SGNL says deny, we
        // don't fetch perm sets or finish the flow; the page renders a
        // denial banner and JS/meta-refresh boots the user to /secur/logout.jsp.
        if (cfg.preLoginCheckEnabled && !preflightLogin()) {
            denied = true;
            denialMessage = cfg.denialMessage;
            return null;
        }

        // Step 1: ask SGNL which permission sets the user may assume.
        SgnlClient.SearchResponse found;
        try {
            found = SgnlClient.searchPermissionSets(SgnlClient.currentPrincipalId(), cfg.routingKeySearch);
        } catch (Exception e) {
            logFailure('search', e);
            errorMessage = MSG_LIST_FAILED;
            return null; // page shows the error and a Continue button
        }
        if (String.isNotBlank(found.nextPageToken)) {
            System.debug(LoggingLevel.WARN, 'SGNL login flow search returned more than one page of permission sets; '
                + 'offering the first page. Narrow the policies that allow activate.');
        }
        List<Id> sgnlIds = toPermSetIds(SgnlClient.allowedAssetIds(found, SgnlClient.ACTION_ACTIVATE));

        Map<Id, String> eligible = new Privileged().eligiblePermSets(sgnlIds);
        // Counts for admins: a large gap or a large count suggests a broad policy
        System.debug(LoggingLevel.INFO, 'SGNL login flow: SGNL allowed ' + sgnlIds.size()
            + ' permission sets; ' + Math.min(eligible.size(), maxPickerOptions) + ' are offered.');
        if (eligible.isEmpty()) {
            return getFinishUrl(); // nothing to activate, pass through silently
        }

        // Iterate sgnlIds, not the map, to keep SGNL's order in the picker
        for (Id psId : sgnlIds) {
            if (availablePermSets.size() >= maxPickerOptions) {
                break;
            }
            if (eligible.containsKey(psId)) {
                availablePermSets.add(new PermSetOption(psId, eligible.get(psId)));
                offeredIds.add(psId);
            }
        }
        if (eligible.size() > availablePermSets.size()) {
            System.debug(LoggingLevel.WARN, 'SGNL login flow: ' + eligible.size() + ' permission sets are eligible, '
                + 'but the picker holds ' + maxPickerOptions + ' because of the Visualforce view state limit. '
                + 'Narrow the policies that allow activate.');
        }
        return null;
    }

    // ---------------------------------------------------------------
    // Called when the user submits their selection
    // ---------------------------------------------------------------
    public PageReference activate() {
        if (denied) {
            return null;
        }
        errorMessage = null;

        List<Id> selectedIds = new List<Id>();
        for (PermSetOption opt : availablePermSets) {
            if (opt.selected == true) {
                selectedIds.add(opt.psId);
            }
        }

        if (selectedIds.isEmpty()) {
            errorMessage = MSG_NO_SELECTION;
            return null;
        }

        // Re-check offer and eligibility before calling SGNL. Assignments can
        // change while the page is open.
        if (!offeredIds.containsAll(selectedIds)
            || !new Privileged().eligiblePermSets(selectedIds).keySet().containsAll(selectedIds)) {
            errorMessage = MSG_NOT_APPROVED;
            return null;
        }

        List<SgnlClient.Query> queries = new List<SgnlClient.Query>();
        for (Id psId : selectedIds) {
            queries.add(new SgnlClient.Query(SgnlClient.ACTION_ACTIVATE, psId));
        }

        System.debug(LoggingLevel.INFO, 'SGNL login flow: ' + selectedIds.size() + ' permission sets selected.');

        Boolean approved;
        try {
            approved = SgnlClient.allAllowedInBatches(SgnlClient.currentPrincipalId(), cfg.routingKeyEvaluate, queries);
        } catch (Exception e) {
            logFailure('submit', e);
            errorMessage = MSG_VERIFY_FAILED;
            return null;
        }
        if (!approved) {
            errorMessage = MSG_NOT_APPROVED;
            return null;
        }

        // DML only after the callout; Apex disallows a callout after
        // uncommitted work in the same transaction.
        try {
            new Privileged().activateSessionPermSets(resolveRootSessionId(), selectedIds);
        } catch (Exception e) {
            logFailure('activate', e);
            errorMessage = MSG_ACTIVATE_FAILED;
            return null;
        }

        return getFinishUrl();
    }

    // ---------------------------------------------------------------
    // Called when the user skips permission set selection
    // ---------------------------------------------------------------
    public PageReference skip() {
        if (denied) {
            return null;
        }
        return getFinishUrl();
    }

    // ---------------------------------------------------------------
    // Pre-login gate: evaluates whether the user is allowed to log in at all.
    // Returns true on allow, false on deny or any error (fail-closed).
    // ---------------------------------------------------------------
    private Boolean preflightLogin() {
        List<SgnlClient.Query> queries = new List<SgnlClient.Query>{
            new SgnlClient.Query(cfg.preLoginAction, null)
        };
        try {
            SgnlClient.EvaluateResponse res = SgnlClient.evaluate(SgnlClient.currentPrincipalId(), cfg.routingKeyEvaluate, queries);
            return SgnlClient.allAllowed(queries, res);
        } catch (Exception e) {
            logFailure('preflight', e);
            return false;
        }
    }

    // De-duplicates and drops anything that isn't a PermissionSet Id instead
    // of failing the whole list.
    @TestVisible
    private static List<Id> toPermSetIds(List<String> raw) {
        List<Id> result = new List<Id>();
        if (raw == null) {
            return result;
        }
        Set<Id> seen = new Set<Id>();
        for (String s : raw) {
            if (String.isBlank(s)) {
                continue;
            }
            Id psId;
            try {
                psId = Id.valueOf(s);
            } catch (Exception e) {
                continue;
            }
            if (psId.getSObjectType() != PermissionSet.SObjectType || seen.contains(psId)) {
                continue;
            }
            seen.add(psId);
            result.add(psId);
        }
        return result;
    }

    // Session perm sets must be activated on the root session; a login flow
    // runs in a child session.
    @TestVisible
    private static Id resolveRootSessionId() {
        if (sessionIdOverride != null) {
            return sessionIdOverride;
        }
        Map<String, String> session = Auth.SessionManagement.getCurrentSession();
        String parentId = session.get('ParentId');
        return String.isNotBlank(parentId) ? parentId : session.get('SessionId');
    }

    private static void logFailure(String step, Exception e) {
        System.debug(LoggingLevel.ERROR, 'SGNL login flow ' + step + ' failed: '
            + e.getTypeName() + ': ' + e.getMessage());
    }

    // ---------------------------------------------------------------
    // Finish the login flow: hands the session back to Salesforce so it
    // routes the user to their intended destination
    // ---------------------------------------------------------------
    private PageReference getFinishUrl() {
        return Auth.SessionManagement.finishLoginFlow();
    }

    // ---------------------------------------------------------------
    // Operations standard users can't perform themselves. Users without View
    // Setup can't read PermissionSetAssignment, and nobody but this controller
    // should create SessionPermSetActivation rows, so these run in system mode
    // and filter to the running user explicitly. They are only reached after
    // the checks in init()/activate() above. Instance methods because Apex
    // doesn't allow static methods on inner classes.
    // ---------------------------------------------------------------
    private without sharing class Privileged {

        // Only session-based sets already assigned to the user can be activated.
        public Map<Id, String> eligiblePermSets(List<Id> ids) {
            Map<Id, String> result = new Map<Id, String>();
            if (ids.isEmpty()) {
                return result;
            }
            for (PermissionSetAssignment psa : [
                SELECT PermissionSetId, PermissionSet.Label
                FROM PermissionSetAssignment
                WHERE AssigneeId = :UserInfo.getUserId()
                AND PermissionSetId IN :ids
                AND PermissionSet.HasActivationRequired = true
                WITH SYSTEM_MODE
            ]) {
                result.put(psa.PermissionSetId, psa.PermissionSet.Label);
            }
            return result;
        }

        public void activateSessionPermSets(Id sessionId, List<Id> psIds) {
            // Skip perm sets already active on this session to avoid DUPLICATE_VALUE
            Set<Id> alreadyActive = new Set<Id>();
            for (SessionPermSetActivation existing : [
                SELECT PermissionSetId FROM SessionPermSetActivation
                WHERE AuthSessionId = :sessionId
                WITH SYSTEM_MODE
            ]) {
                alreadyActive.add(existing.PermissionSetId);
            }

            List<SessionPermSetActivation> activations = new List<SessionPermSetActivation>();
            for (Id psId : psIds) {
                if (alreadyActive.contains(psId)) { continue; }
                activations.add(new SessionPermSetActivation(
                    PermissionSetId = psId,
                    AuthSessionId   = sessionId
                ));
            }
            if (!activations.isEmpty()) {
                Database.insert(activations, AccessLevel.SYSTEM_MODE);
            }
        }
    }

    // ---------------------------------------------------------------
    // Inner wrapper used by the VF checkbox list
    // ---------------------------------------------------------------
    public class PermSetOption {
        public Id      psId     { get; private set; }
        public String  label    { get; private set; }
        public Boolean selected { get; set; }

        public PermSetOption(Id psId, String label) {
            this.psId     = psId;
            this.label    = label;
            this.selected = false;
        }
    }
}
