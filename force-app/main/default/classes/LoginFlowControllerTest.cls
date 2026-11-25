@IsTest
private class LoginFlowControllerTest {

    private static final String PS_ASSIGNED   = 'LFT_Assigned_Session';
    private static final String PS_UNASSIGNED = 'LFT_Unassigned_Session';
    private static final String PS_REGULAR    = 'LFT_Assigned_Regular';

    // ------------------------------------------------------------------
    // Mock that returns SGNL-shaped responses, routed on the query action.
    // listBody == null or evaluateDecision == null makes that call throw.
    //
    // List responses use SGNL's search response {decisions, nextPageToken}.
    // Evaluate responses echo each query's action/assetId with the configured
    // decision, matching the real AccessEvaluationResponse.
    // ------------------------------------------------------------------
    private class SgnlMock implements HttpCalloutMock {
        private final String listBody;
        private final String evaluateDecision;
        public Integer evaluateCalls = 0;

        SgnlMock(String listBody, String evaluateDecision) {
            this.listBody         = listBody;
            this.evaluateDecision = evaluateDecision;
        }

        public HttpResponse respond(HttpRequest req) {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
            List<Object> queries = (List<Object>) body.get('queries');
            String action = (String) ((Map<String, Object>) queries[0]).get('action');

            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);

            if (action == SgnlClient.ACTION_LIST_PERMISSION_SETS) {
                if (listBody == null) { throw new CalloutException('list unavailable'); }
                res.setBody(listBody);
                return res;
            }

            evaluateCalls++;
            if (evaluateDecision == null) { throw new CalloutException('evaluate unavailable'); }
            List<Object> decisions = new List<Object>();
            for (Object q : queries) {
                Map<String, Object> query = (Map<String, Object>) q;
                Map<String, Object> d = new Map<String, Object>{
                    'action'   => query.get('action'),
                    'decision' => evaluateDecision
                };
                if (query.containsKey('assetId')) {
                    d.put('assetId', query.get('assetId'));
                }
                decisions.add(d);
            }
            res.setBody(JSON.serialize(new Map<String, Object>{ 'decisions' => decisions }));
            return res;
        }
    }

    @TestSetup
    static void setup() {
        PermissionSet assigned   = new PermissionSet(Name = PS_ASSIGNED,   Label = 'LFT Assigned Session',   HasActivationRequired = true);
        PermissionSet unassigned = new PermissionSet(Name = PS_UNASSIGNED, Label = 'LFT Unassigned Session', HasActivationRequired = true);
        PermissionSet regular    = new PermissionSet(Name = PS_REGULAR,    Label = 'LFT Assigned Regular',   HasActivationRequired = false);
        insert new List<PermissionSet>{ assigned, unassigned, regular };

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(PermissionSetId = assigned.Id, AssigneeId = UserInfo.getUserId()),
            new PermissionSetAssignment(PermissionSetId = regular.Id,  AssigneeId = UserInfo.getUserId())
        };
    }

    private static Id psId(String name) {
        return [SELECT Id FROM PermissionSet WHERE Name = :name LIMIT 1].Id;
    }

    private static String listBody(List<Id> ids) {
        return listBody(ids, 'Allow', null);
    }

    private static String listBody(List<Id> ids, String decision, String nextPageToken) {
        List<Object> decisions = new List<Object>();
        for (Id psId : ids) {
            decisions.add(new Map<String, Object>{
                'assetId'  => psId,
                'action'   => SgnlClient.ACTION_LIST_PERMISSION_SETS,
                'decision' => decision
            });
        }
        Map<String, Object> body = new Map<String, Object>{ 'decisions' => decisions };
        if (nextPageToken != null) {
            body.put('nextPageToken', nextPageToken);
        }
        return JSON.serialize(body);
    }

    private static void useConfig(Boolean preLoginEnabled) {
        LoginFlowConfig.setMockForTest(LoginFlowConfig.buildForTest(
            'org_search', 'org_evaluate',
            preLoginEnabled, 'login',
            'Access denied.', 10
        ));
    }

    // Controller with the assigned session perm set offered and selected
    private static LoginFlowController initWithAssignedSelected(SgnlMock m) {
        Test.setMock(HttpCalloutMock.class, m);
        LoginFlowController ctrl = new LoginFlowController();
        ctrl.init();
        Assert.areEqual(1, ctrl.availablePermSets.size(), 'Precondition: one option offered');
        ctrl.availablePermSets[0].selected = true;
        return ctrl;
    }

    // ---------------- init ----------------

    @IsTest
    static void init_offersAssignedSessionPermSets() {
        useConfig(false);
        Test.setMock(HttpCalloutMock.class, new SgnlMock(listBody(new List<Id>{ psId(PS_ASSIGNED) }), 'Allow'));

        Test.startTest();
        LoginFlowController ctrl = new LoginFlowController();
        PageReference result = ctrl.init();
        Test.stopTest();

        Assert.areEqual(1, ctrl.availablePermSets.size());
        Assert.areEqual('LFT Assigned Session', ctrl.availablePermSets[0].label);
        Assert.isFalse(ctrl.denied);
        Assert.isNull(ctrl.errorMessage);
        Assert.isNull(result, 'init() should stay on page');
    }

    @IsTest
    static void init_dropsUnassignedAndNonSessionSets() {
        useConfig(false);
        Test.setMock(HttpCalloutMock.class, new SgnlMock(
            listBody(new List<Id>{ psId(PS_ASSIGNED), psId(PS_UNASSIGNED), psId(PS_REGULAR) }), 'Allow'));

        Test.startTest();
        LoginFlowController ctrl = new LoginFlowController();
        ctrl.init();
        Test.stopTest();

        Assert.areEqual(1, ctrl.availablePermSets.size());
        Assert.areEqual(psId(PS_ASSIGNED), ctrl.availablePermSets[0].psId);
    }

    @IsTest
    static void init_noEligibleSets_passesThrough() {
        useConfig(false);
        Test.setMock(HttpCalloutMock.class, new SgnlMock(listBody(new List<Id>{ psId(PS_UNASSIGNED) }), 'Allow'));

        Test.startTest();
        LoginFlowController ctrl = new LoginFlowController();
        ctrl.init();
        Test.stopTest();

        Assert.areEqual(0, ctrl.availablePermSets.size());
        Assert.isNull(ctrl.errorMessage, 'Nothing to activate is not an error');
    }

    @IsTest
    static void toPermSetIds_dedupesAndSkipsInvalid() {
        Id ps = psId(PS_ASSIGNED);
        List<Id> result = LoginFlowController.toPermSetIds(new List<String>{
            'not-an-id', ps, String.valueOf(ps).left(15), UserInfo.getUserId(), null
        });
        Assert.areEqual(new List<Id>{ ps }, result);
        Assert.areEqual(0, LoginFlowController.toPermSetIds(null).size());
    }

    @IsTest
    static void init_whenSgnlDeniesEverySet_passesThrough() {
        useConfig(false);
        Test.setMock(HttpCalloutMock.class, new SgnlMock(listBody(new List<Id>{ psId(PS_ASSIGNED) }, 'Deny', null), 'Allow'));

        Test.startTest();
        LoginFlowController ctrl = new LoginFlowController();
        ctrl.init();
        Test.stopTest();

        Assert.areEqual(0, ctrl.availablePermSets.size(), 'A Deny decision must not be offered');
        Assert.isNull(ctrl.errorMessage, 'Nothing allowed is not an error');
    }

    @IsTest
    static void init_withMorePages_offersTheFirstPage() {
        useConfig(false);
        Test.setMock(HttpCalloutMock.class, new SgnlMock(listBody(new List<Id>{ psId(PS_ASSIGNED) }, 'Allow', 'page-2'), 'Allow'));

        Test.startTest();
        LoginFlowController ctrl = new LoginFlowController();
        ctrl.init();
        Test.stopTest();

        Assert.areEqual(1, ctrl.availablePermSets.size());
        Assert.isNull(ctrl.errorMessage);
    }

    @IsTest
    static void init_whenListFails_setsError() {
        useConfig(false);
        Test.setMock(HttpCalloutMock.class, new SgnlMock(null, 'Allow'));

        Test.startTest();
        LoginFlowController ctrl = new LoginFlowController();
        PageReference result = ctrl.init();
        Test.stopTest();

        Assert.areEqual(LoginFlowController.MSG_LIST_FAILED, ctrl.errorMessage);
        Assert.isNull(result);
        Assert.isFalse(ctrl.denied, 'List failure is not a login denial');
    }

    @IsTest
    static void init_whenPreflightAllows_proceedsToPermSets() {
        useConfig(true);
        Test.setMock(HttpCalloutMock.class, new SgnlMock(listBody(new List<Id>{ psId(PS_ASSIGNED) }), 'Allow'));

        Test.startTest();
        LoginFlowController ctrl = new LoginFlowController();
        ctrl.init();
        Test.stopTest();

        Assert.isFalse(ctrl.denied);
        Assert.areEqual(1, ctrl.availablePermSets.size());
    }

    @IsTest
    static void init_whenPreflightDenies_setsDenied() {
        useConfig(true);
        Test.setMock(HttpCalloutMock.class, new SgnlMock(listBody(new List<Id>{ psId(PS_ASSIGNED) }), 'Deny'));

        Test.startTest();
        LoginFlowController ctrl = new LoginFlowController();
        PageReference result = ctrl.init();
        Test.stopTest();

        Assert.isTrue(ctrl.denied);
        Assert.areEqual('Access denied.', ctrl.denialMessage);
        Assert.areEqual(0, ctrl.availablePermSets.size(), 'No perm sets loaded after deny');
        Assert.isNull(result, 'init() returns null so the page renders the denial state');
    }

    @IsTest
    static void init_whenPreflightFails_failsClosed() {
        useConfig(true);
        Test.setMock(HttpCalloutMock.class, new SgnlMock(listBody(new List<Id>{ psId(PS_ASSIGNED) }), null));

        Test.startTest();
        LoginFlowController ctrl = new LoginFlowController();
        ctrl.init();
        Test.stopTest();

        Assert.isTrue(ctrl.denied, 'SGNL failure during preflight must deny');
    }

    // ---------------- activate / skip ----------------

    @IsTest
    static void activate_withNoSelection_setsError() {
        useConfig(false);
        Test.setMock(HttpCalloutMock.class, new SgnlMock(listBody(new List<Id>{ psId(PS_ASSIGNED) }), 'Allow'));

        Test.startTest();
        LoginFlowController ctrl = new LoginFlowController();
        ctrl.init();
        PageReference result = ctrl.activate();
        Test.stopTest();

        Assert.isNull(result);
        Assert.areEqual(LoginFlowController.MSG_NO_SELECTION, ctrl.errorMessage);
    }

    @IsTest
    static void activate_whenValidationDenied_setsError() {
        useConfig(false);

        Test.startTest();
        LoginFlowController ctrl = initWithAssignedSelected(new SgnlMock(listBody(new List<Id>{ psId(PS_ASSIGNED) }), 'Deny'));
        PageReference result = ctrl.activate();
        Test.stopTest();

        Assert.isNull(result);
        Assert.areEqual(LoginFlowController.MSG_NOT_APPROVED, ctrl.errorMessage);
    }

    @IsTest
    static void activate_whenValidationFails_setsError() {
        useConfig(false);

        Test.startTest();
        LoginFlowController ctrl = initWithAssignedSelected(new SgnlMock(listBody(new List<Id>{ psId(PS_ASSIGNED) }), null));
        PageReference result = ctrl.activate();
        Test.stopTest();

        Assert.isNull(result);
        Assert.areEqual(LoginFlowController.MSG_VERIFY_FAILED, ctrl.errorMessage);
    }

    @IsTest
    static void activate_rejectsSelectionNotOffered() {
        useConfig(false);
        SgnlMock m = new SgnlMock(listBody(new List<Id>{ psId(PS_ASSIGNED) }), 'Allow');

        Test.startTest();
        LoginFlowController ctrl = initWithAssignedSelected(m);
        LoginFlowController.PermSetOption extra = new LoginFlowController.PermSetOption(psId(PS_UNASSIGNED), 'injected');
        extra.selected = true;
        ctrl.availablePermSets.add(extra);
        PageReference result = ctrl.activate();
        Test.stopTest();

        Assert.isNull(result);
        Assert.areEqual(LoginFlowController.MSG_NOT_APPROVED, ctrl.errorMessage);
        Assert.areEqual(0, m.evaluateCalls, 'SGNL must not be asked about an unoffered selection');
    }

    @IsTest
    static void activate_whenAssignmentRemoved_setsError() {
        useConfig(false);
        SgnlMock m = new SgnlMock(listBody(new List<Id>{ psId(PS_ASSIGNED) }), 'Allow');

        Test.startTest();
        LoginFlowController ctrl = initWithAssignedSelected(m);
        delete [SELECT Id FROM PermissionSetAssignment
                WHERE PermissionSet.Name = :PS_ASSIGNED AND AssigneeId = :UserInfo.getUserId()];
        PageReference result = ctrl.activate();
        Test.stopTest();

        Assert.isNull(result);
        Assert.areEqual(LoginFlowController.MSG_NOT_APPROVED, ctrl.errorMessage);
        Assert.areEqual(0, m.evaluateCalls);
    }

    @IsTest
    static void activate_whenInsertFails_setsError() {
        useConfig(false);
        // No real AuthSession can exist in a test, so the insert must fail
        LoginFlowController.sessionIdOverride = Id.valueOf('0Ak000000000001');

        Test.startTest();
        LoginFlowController ctrl = initWithAssignedSelected(new SgnlMock(listBody(new List<Id>{ psId(PS_ASSIGNED) }), 'Allow'));
        PageReference result = ctrl.activate();
        Test.stopTest();

        Assert.isNull(result);
        Assert.areEqual(LoginFlowController.MSG_ACTIVATE_FAILED, ctrl.errorMessage);
    }

    @IsTest
    static void activateAndSkip_whenDenied_doNothing() {
        useConfig(true);
        SgnlMock m = new SgnlMock(listBody(new List<Id>{ psId(PS_ASSIGNED) }), 'Deny');

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, m);
        LoginFlowController ctrl = new LoginFlowController();
        ctrl.init();
        Integer callsAfterInit = m.evaluateCalls;
        PageReference activateResult = ctrl.activate();
        PageReference skipResult = ctrl.skip();
        Test.stopTest();

        Assert.isTrue(ctrl.denied);
        Assert.isNull(activateResult);
        Assert.isNull(skipResult);
        Assert.areEqual(callsAfterInit, m.evaluateCalls, 'activate() must not call SGNL when denied');
    }

    // NOTE: the successful SessionPermSetActivation insert is not unit-tested:
    // it needs a real AuthSession, which can't exist in @IsTest context.
    // Validate this path manually in a sandbox with the Login Flow assigned.
}
