@IsTest
private class LoginFlowAdminControllerTest {

    private class Mock implements HttpCalloutMock {
        private final Integer status;
        private final Boolean throwCallout;
        public HttpRequest lastRequest;

        Mock(Integer status, Boolean throwCallout) {
            this.status       = status;
            this.throwCallout = throwCallout;
        }

        public HttpResponse respond(HttpRequest req) {
            lastRequest = req;
            if (throwCallout) {
                throw new CalloutException('Unable to fetch an access token');
            }
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setBody('{"decisions":[]}');
            return res;
        }
    }

    private static void useConfig() {
        LoginFlowConfig.setMockForTest(LoginFlowConfig.buildForTest(true, 'login', 'Denied.', 15));
    }

    @IsTest
    static void getConfig_returnsEffectiveConfig() {
        useConfig();

        LoginFlowAdminController.ConfigDTO dto = LoginFlowAdminController.getConfig();

        Assert.areEqual(SgnlClient.NAMED_CREDENTIAL, dto.namedCredential);
        Assert.areEqual('/v1/evaluations', dto.evaluationsPath);
        Assert.areEqual('/v1/search/assets', dto.searchPath);
        Assert.areEqual('{$.context.orgId}', dto.applicationIdPath);
        Assert.areEqual(UserInfo.getOrganizationId().left(15), dto.applicationId);
        Assert.isTrue(dto.preLoginCheckEnabled);
        Assert.areEqual('login', dto.preLoginAction);
        Assert.areEqual('Denied.', dto.denialMessage);
        Assert.areEqual(15, dto.denialAutoLogoutSecs);
        Assert.isFalse(dto.hasConfigRecord);
        Assert.isFalse(dto.preLoginActionIsDefault);
        Assert.isFalse(dto.denialMessageIsDefault);
        Assert.isFalse(dto.denialAutoLogoutSecsIsDefault);
        // Edit page for the org's Default record, or the new-record page if there isn't one
        LoginFlow_Config__mdt rec = LoginFlow_Config__mdt.getInstance('Default');
        String target = rec != null ? rec.Id : LoginFlow_Config__mdt.SObjectType.getDescribe().getKeyPrefix();
        Assert.areEqual(
            '/lightning/setup/CustomMetadata/page?address=%2F' + target + '%2Fe%3FretURL%3D%252F' + target,
            dto.setupUrl);
    }

    @IsTest
    static void getConfig_reportsCredentialStatusAndSetupLinks() {
        useConfig();
        LoginFlowAdminController.credentialStatusOverride = 'NotConfigured';

        LoginFlowAdminController.ConfigDTO dto = LoginFlowAdminController.getConfig();

        Assert.areEqual('NotConfigured', dto.credentialStatus);
        Assert.areEqual('/lightning/setup/NamedCredential/home', dto.credentialSetupUrl);
        Assert.areEqual('/lightning/setup/LoginFlow/home', dto.loginFlowSetupUrl);
    }

    @IsTest
    static void credentialStatus_neverThrows() {
        // Whether or not ConnectApi works in a test context, this must not throw
        String status = LoginFlowAdminController.credentialStatus();

        Assert.isTrue(String.isNotBlank(status), 'Expected a status, got ' + status);
    }

    @IsTest
    static void testConnection_ok_runsTheLoginSearch() {
        useConfig();
        Mock m = new Mock(200, false);
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        LoginFlowAdminController.TestResultDTO r = LoginFlowAdminController.testConnection();
        Test.stopTest();

        Assert.isTrue(r.ok);
        Assert.areEqual(200, r.statusCode);
        Assert.isNull(r.hintText);
        Assert.areEqual('callout:NGIS_SGNL_Access/v1/search/assets?pageSize=200', m.lastRequest.getEndpoint());
        Map<String, Object> query = (Map<String, Object>) ((List<Object>)
            ((Map<String, Object>) JSON.deserializeUntyped(m.lastRequest.getBody())).get('queries'))[0];
        Assert.areEqual('assumePermissionSet', query.get('action'));
    }

    @IsTest
    static void testConnection_hintsPerStatus() {
        useConfig();
        Map<Integer, String> expected = new Map<Integer, String>{
            400 => LoginFlowAdminController.HINT_BAD_REQUEST,
            401 => LoginFlowAdminController.HINT_UNAUTHORIZED,
            403 => LoginFlowAdminController.HINT_FORBIDDEN
        };

        Test.startTest();
        for (Integer status : expected.keySet()) {
            Test.setMock(HttpCalloutMock.class, new Mock(status, false));
            LoginFlowAdminController.TestResultDTO r = LoginFlowAdminController.testConnection();
            Assert.isFalse(r.ok);
            Assert.areEqual(status, r.statusCode);
            Assert.areEqual(expected.get(status), r.hintText, 'hint for ' + status);
        }
        Test.stopTest();
    }

    @IsTest
    static void testConnection_serverError_noHint() {
        useConfig();
        Test.setMock(HttpCalloutMock.class, new Mock(500, false));

        Test.startTest();
        LoginFlowAdminController.TestResultDTO r = LoginFlowAdminController.testConnection();
        Test.stopTest();

        Assert.isFalse(r.ok);
        Assert.areEqual(500, r.statusCode);
        Assert.isNull(r.hintText);
    }

    @IsTest
    static void testConnection_calloutException_isReported() {
        useConfig();
        Test.setMock(HttpCalloutMock.class, new Mock(null, true));

        Test.startTest();
        LoginFlowAdminController.TestResultDTO r = LoginFlowAdminController.testConnection();
        Test.stopTest();

        Assert.isFalse(r.ok);
        Assert.areEqual(0, r.statusCode);
        Assert.isTrue(r.body.contains('Unable to fetch an access token'), r.body);
        Assert.areEqual(LoginFlowAdminController.HINT_CALLOUT_FAILED, r.hintText);
    }
}
