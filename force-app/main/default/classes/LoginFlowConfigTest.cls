@IsTest
private class LoginFlowConfigTest {

    @IsTest
    static void load_withoutRecord_usesDefaults() {
        LoginFlowConfig c = LoginFlowConfig.load(null);

        Assert.isFalse(c.hasConfigRecord);
        Assert.isFalse(c.preLoginCheckEnabled);
        Assert.areEqual('login', c.preLoginAction);
        Assert.isTrue(String.isNotBlank(c.denialMessage));
        Assert.areEqual(10, c.denialAutoLogoutSecs);
        Assert.isTrue(c.preLoginActionIsDefault);
        Assert.isTrue(c.denialMessageIsDefault);
        Assert.isTrue(c.denialAutoLogoutSecsIsDefault);
    }

    @IsTest
    static void load_withRecord_appliesOverrides() {
        LoginFlow_Config__mdt r = new LoginFlow_Config__mdt(
            Pre_Login_Check_Enabled__c    = true,
            Pre_Login_Action__c           = 'signin',
            Denial_Message__c             = 'Nope.',
            Denial_Auto_Logout_Seconds__c = 30
        );

        LoginFlowConfig c = LoginFlowConfig.load(r);

        Assert.isTrue(c.hasConfigRecord);
        Assert.isTrue(c.preLoginCheckEnabled);
        Assert.areEqual('signin', c.preLoginAction);
        Assert.areEqual('Nope.', c.denialMessage);
        Assert.areEqual(30, c.denialAutoLogoutSecs);
        Assert.isFalse(c.preLoginActionIsDefault);
        Assert.isFalse(c.denialMessageIsDefault);
        Assert.isFalse(c.denialAutoLogoutSecsIsDefault);
    }

    @IsTest
    static void load_withBlankFields_fallsBackPerField() {
        LoginFlowConfig c = LoginFlowConfig.load(new LoginFlow_Config__mdt(Pre_Login_Action__c = ' '));

        Assert.isTrue(c.hasConfigRecord);
        Assert.areEqual('login', c.preLoginAction);
        Assert.isTrue(String.isNotBlank(c.denialMessage));
        Assert.isTrue(c.preLoginActionIsDefault);
        Assert.isTrue(c.denialMessageIsDefault);
        Assert.isTrue(c.denialAutoLogoutSecsIsDefault);
    }

    @IsTest
    static void load_clampsLogoutSeconds() {
        Assert.areEqual(600, LoginFlowConfig.load(new LoginFlow_Config__mdt(Denial_Auto_Logout_Seconds__c = 9999)).denialAutoLogoutSecs);
        Assert.areEqual(10, LoginFlowConfig.load(new LoginFlow_Config__mdt(Denial_Auto_Logout_Seconds__c = 0)).denialAutoLogoutSecs);
        Assert.areEqual(10, LoginFlowConfig.load(new LoginFlow_Config__mdt(Denial_Auto_Logout_Seconds__c = -5)).denialAutoLogoutSecs);
    }

    @IsTest
    static void getInstance_prefersMockThenCaches() {
        LoginFlowConfig m = LoginFlowConfig.buildForTest(true, 'login', 'x', 5);
        LoginFlowConfig.setMockForTest(m);
        Assert.areEqual(m, LoginFlowConfig.getInstance());

        LoginFlowConfig.setMockForTest(null);
        LoginFlowConfig first = LoginFlowConfig.getInstance();
        Assert.isNotNull(first.preLoginAction);
        Assert.areEqual(first, LoginFlowConfig.getInstance(), 'Second call should return the cached instance');
    }
}
