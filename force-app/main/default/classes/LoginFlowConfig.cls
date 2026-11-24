/**
 * Central config accessor for the login flow.
 *
 * Reads optional overrides from the LoginFlow_Config__mdt.Default record,
 * which admins edit in Setup > Custom Metadata Types. Every value has a
 * default, so the flow runs correctly with no record at all. Values are
 * cached for the duration of the request. Tests can inject an instance via
 * setMockForTest() to avoid depending on a deployed CMT row.
 */
public with sharing class LoginFlowConfig {

    public static final String DEFAULT_RECORD = 'Default';

    private static final String  DEFAULT_PRELOGIN_ACTION = 'login';
    private static final String  DEFAULT_DENY_MSG        = 'Your account is not authorized to access this org right now. You will be signed out automatically.';
    private static final Integer DEFAULT_DENY_SECONDS    = 10;
    private static final Integer MAX_DENY_SECONDS        = 600;

    public Boolean preLoginCheckEnabled { get; private set; }
    public String  preLoginAction       { get; private set; }
    public String  denialMessage        { get; private set; }
    public Integer denialAutoLogoutSecs { get; private set; }

    // True when the Default record exists (shown in the admin UI)
    public Boolean hasConfigRecord      { get; private set; }

    // True when the value isn't set on the record, so the built-in default applies
    public Boolean preLoginActionIsDefault       { get; private set; }
    public Boolean denialMessageIsDefault        { get; private set; }
    public Boolean denialAutoLogoutSecsIsDefault { get; private set; }

    private static LoginFlowConfig cached;
    private static LoginFlowConfig mock;

    // ---------------- Public API ----------------

    public static LoginFlowConfig getInstance() {
        if (mock != null) { return mock; }
        if (cached == null) { cached = load(LoginFlow_Config__mdt.getInstance(DEFAULT_RECORD)); }
        return cached;
    }

    @TestVisible
    private static void setMockForTest(LoginFlowConfig m) {
        mock = m;
    }

    /**
     * Test-only factory so unit tests can build an in-memory instance without
     * inserting the CMT row (which isn't creatable via DML in a test context).
     */
    @TestVisible
    private static LoginFlowConfig buildForTest(
        Boolean preLoginEnabled, String preLoginAction,
        String denialMsg, Integer denialSecs
    ) {
        LoginFlowConfig c = new LoginFlowConfig();
        c.preLoginCheckEnabled = preLoginEnabled;
        c.preLoginAction       = preLoginAction;
        c.denialMessage        = denialMsg;
        c.denialAutoLogoutSecs = denialSecs;
        c.hasConfigRecord      = false;
        c.preLoginActionIsDefault       = false;
        c.denialMessageIsDefault        = false;
        c.denialAutoLogoutSecsIsDefault = false;
        return c;
    }

    // ---------------- Internals ----------------

    @TestVisible
    private static LoginFlowConfig load(LoginFlow_Config__mdt r) {
        LoginFlowConfig c = new LoginFlowConfig();
        c.hasConfigRecord      = r != null;
        c.preLoginCheckEnabled = r?.Pre_Login_Check_Enabled__c == true;
        c.preLoginAction       = blankFallback(r?.Pre_Login_Action__c, DEFAULT_PRELOGIN_ACTION);
        c.denialMessage        = blankFallback(r?.Denial_Message__c, DEFAULT_DENY_MSG);
        c.denialAutoLogoutSecs = clampSeconds(r?.Denial_Auto_Logout_Seconds__c);
        c.preLoginActionIsDefault       = String.isBlank(r?.Pre_Login_Action__c);
        c.denialMessageIsDefault        = String.isBlank(r?.Denial_Message__c);
        c.denialAutoLogoutSecsIsDefault = r?.Denial_Auto_Logout_Seconds__c == null
            || r.Denial_Auto_Logout_Seconds__c < 1;
        return c;
    }

    private static String blankFallback(String v, String fallback) {
        return String.isBlank(v) ? fallback : v;
    }

    private static Integer clampSeconds(Decimal v) {
        if (v == null || v < 1) { return DEFAULT_DENY_SECONDS; }
        return Math.min(Integer.valueOf(v), MAX_DENY_SECONDS);
    }
}
