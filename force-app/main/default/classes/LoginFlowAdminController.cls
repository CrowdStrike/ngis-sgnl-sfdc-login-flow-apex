/**
 * Backing controller for the loginFlowAdmin LWC.
 *
 * Read-only: shows the effective configuration, the SGNL provider hook
 * values for this org, and links to Setup, where
 * admins edit the LoginFlow_Config__mdt.Default record (needs Customize
 * Application). Also exposes a test-connection endpoint that fires a
 * listPermissionSets call through the NGIS_SGNL_Access Named Credential so
 * admins can verify credentials without triggering a real login flow.
 */
public with sharing class LoginFlowAdminController {

    @TestVisible private static final String HINT_CALLOUT_FAILED =
        'The call failed before reaching SGNL. Check the client id and secret on the '
        + 'NGIS_SGNL_Falcon_OAuth principal, that the token URL and the NGIS_SGNL_Access URL '
        + 'match your Falcon cloud, and that you have the NGIS SGNL Login Flow Admin permission set.';
    @TestVisible private static final String HINT_UNAUTHORIZED =
        'The authorizer rejected the request. Check that the Falcon API client has the '
        + 'sgnl-access:read scope and is mapped to your SGNL provider.';

    @TestVisible private static final String EXTERNAL_CREDENTIAL = 'NGIS_SGNL_Falcon_OAuth';
    @TestVisible private static final String PRINCIPAL           = 'NGIS_SGNL_Principal';
    @TestVisible private static final String CREDENTIAL_UNKNOWN  = 'Unknown';
    private static final String CREDENTIAL_SETUP_URL = '/lightning/setup/NamedCredential/home';
    private static final String LOGIN_FLOW_SETUP_URL = '/lightning/setup/LoginFlow/home';

    // ConnectApi.NamedCredentials can't run in unit tests; tests set the status here
    @TestVisible private static String credentialStatusOverride;

    @AuraEnabled(cacheable=false)
    public static ConfigDTO getConfig() {
        LoginFlowConfig c = LoginFlowConfig.getInstance();
        ConfigDTO dto = new ConfigDTO();
        dto.namedCredential      = SgnlClient.NAMED_CREDENTIAL;
        dto.apiPath              = SgnlClient.PATH;
        dto.routingKeyPath       = SgnlClient.ROUTING_KEY_PATH;
        dto.routingKeySearch     = c.routingKeySearch;
        dto.routingKeyEvaluate   = c.routingKeyEvaluate;
        dto.preLoginCheckEnabled = c.preLoginCheckEnabled;
        dto.preLoginAction       = c.preLoginAction;
        dto.denialMessage        = c.denialMessage;
        dto.denialAutoLogoutSecs = c.denialAutoLogoutSecs;
        dto.hasConfigRecord      = c.hasConfigRecord;
        dto.preLoginActionIsDefault       = c.preLoginActionIsDefault;
        dto.denialMessageIsDefault        = c.denialMessageIsDefault;
        dto.denialAutoLogoutSecsIsDefault = c.denialAutoLogoutSecsIsDefault;
        dto.setupUrl             = setupUrl();
        dto.credentialStatus     = credentialStatus();
        dto.credentialSetupUrl   = CREDENTIAL_SETUP_URL;
        dto.loginFlowSetupUrl    = LOGIN_FLOW_SETUP_URL;
        return dto;
    }

    /**
     * Whether the External Credential principal has client credentials:
     * Configured, NotConfigured, or Unknown when the status can't be read
     * (for example, the admin lacks the permission ConnectApi needs).
     */
    @TestVisible
    private static String credentialStatus() {
        if (credentialStatusOverride != null) { return credentialStatusOverride; }
        try {
            ConnectApi.Credential c = ConnectApi.NamedCredentials.getCredential(
                EXTERNAL_CREDENTIAL, PRINCIPAL, ConnectApi.CredentialPrincipalType.NamedPrincipal);
            return c.authenticationStatus == null ? CREDENTIAL_UNKNOWN : String.valueOf(c.authenticationStatus);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'SGNL login flow credential status failed: ' + e.getMessage());
            return CREDENTIAL_UNKNOWN;
        }
    }

    /**
     * The Setup edit page for the Default LoginFlow_Config record, or the
     * new-record page when there's no Default record yet. retURL sends Cancel
     * to the record (or the record list); without it Cancel lands on a page
     * that doesn't exist in Lightning Setup.
     */
    @TestVisible
    private static String setupUrl() {
        LoginFlow_Config__mdt rec = LoginFlow_Config__mdt.getInstance(LoginFlowConfig.DEFAULT_RECORD);
        String target = rec != null
            ? rec.Id
            : LoginFlow_Config__mdt.SObjectType.getDescribe().getKeyPrefix();
        String editPage = '/' + target + '/e?retURL=' + EncodingUtil.urlEncode('/' + target, 'UTF-8');
        return '/lightning/setup/CustomMetadata/page?address=' + EncodingUtil.urlEncode(editPage, 'UTF-8');
    }

    /**
     * Fires a listPermissionSets call against SGNL as the current user using
     * the saved config. Never throws for auth/HTTP errors, so the UI can show
     * useful diagnostics.
     */
    @AuraEnabled
    public static TestResultDTO testConnection() {
        LoginFlowConfig c = LoginFlowConfig.getInstance();
        TestResultDTO result = new TestResultDTO();
        try {
            HttpResponse res = SgnlClient.send(SgnlClient.currentPrincipalId(), c.routingKeySearch, new List<SgnlClient.Query>{
                new SgnlClient.Query(SgnlClient.ACTION_LIST_PERMISSION_SETS, null)
            });
            result.statusCode = res.getStatusCode();
            result.body       = res.getBody();
            result.ok         = result.statusCode >= 200 && result.statusCode < 300;
            if (result.statusCode == 401 || result.statusCode == 403) {
                result.hintText = HINT_UNAUTHORIZED;
            }
        } catch (Exception e) {
            // Includes External Credential token-fetch failures
            result.ok         = false;
            result.statusCode = 0;
            result.body       = e.getTypeName() + ': ' + e.getMessage();
            result.hintText   = HINT_CALLOUT_FAILED;
        }
        return result;
    }

    public class ConfigDTO {
        @AuraEnabled public String  namedCredential      { get; set; }
        @AuraEnabled public String  apiPath              { get; set; }
        // What the SGNL admin enters on the provider hook for this org: the
        // application Id path, and one integration assignment per routing key
        @AuraEnabled public String  routingKeyPath       { get; set; }
        @AuraEnabled public String  routingKeySearch     { get; set; }
        @AuraEnabled public String  routingKeyEvaluate   { get; set; }
        @AuraEnabled public Boolean preLoginCheckEnabled { get; set; }
        @AuraEnabled public String  preLoginAction       { get; set; }
        @AuraEnabled public String  denialMessage        { get; set; }
        @AuraEnabled public Integer denialAutoLogoutSecs { get; set; }
        @AuraEnabled public Boolean hasConfigRecord      { get; set; }
        // True when the field is blank on the record and the built-in default applies
        @AuraEnabled public Boolean preLoginActionIsDefault       { get; set; }
        @AuraEnabled public Boolean denialMessageIsDefault        { get; set; }
        @AuraEnabled public Boolean denialAutoLogoutSecsIsDefault { get; set; }
        @AuraEnabled public String  setupUrl             { get; set; }
        // Setup checklist: credential status (Configured, NotConfigured or
        // Unknown) and where to fix each step
        @AuraEnabled public String  credentialStatus     { get; set; }
        @AuraEnabled public String  credentialSetupUrl   { get; set; }
        @AuraEnabled public String  loginFlowSetupUrl    { get; set; }
    }

    public class TestResultDTO {
        @AuraEnabled public Boolean ok         { get; set; }
        @AuraEnabled public Integer statusCode { get; set; }
        @AuraEnabled public String  body       { get; set; }
        // "hint" is a reserved word in Apex
        @AuraEnabled public String  hintText   { get; set; }
    }
}
