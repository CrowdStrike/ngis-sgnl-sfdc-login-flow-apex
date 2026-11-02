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
        dto.setupUrl             = setupUrl();
        return dto;
    }

    /**
     * The Setup detail page for the LoginFlow_Config custom metadata type,
     * which lists its fields and has Manage Records. Linking to the key
     * prefix instead lands on the bare record list, which is empty until a
     * Default record exists.
     */
    @TestVisible
    private static String setupUrl() {
        List<EntityDefinition> defs = [
            SELECT DurableId FROM EntityDefinition
            WHERE QualifiedApiName = 'LoginFlow_Config__mdt' LIMIT 1
        ];
        String target = defs.isEmpty()
            ? LoginFlow_Config__mdt.SObjectType.getDescribe().getKeyPrefix()
            : defs[0].DurableId;
        return '/lightning/setup/CustomMetadata/page?address=%2F' + target;
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
        @AuraEnabled public String  setupUrl             { get; set; }
    }

    public class TestResultDTO {
        @AuraEnabled public Boolean ok         { get; set; }
        @AuraEnabled public Integer statusCode { get; set; }
        @AuraEnabled public String  body       { get; set; }
        // "hint" is a reserved word in Apex
        @AuraEnabled public String  hintText   { get; set; }
    }
}
