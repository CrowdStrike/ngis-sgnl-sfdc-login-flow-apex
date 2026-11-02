import { LightningElement } from 'lwc';
import getConfig from '@salesforce/apex/LoginFlowAdminController.getConfig';
import testConnection from '@salesforce/apex/LoginFlowAdminController.testConnection';

export default class LoginFlowAdmin extends LightningElement {
    cfg;
    loadError;
    loading = false;
    testing = false;
    testResult;

    connectedCallback() {
        this.load();
    }

    async load() {
        this.loading = true;
        this.loadError = undefined;
        try {
            this.cfg = await getConfig();
        } catch (e) {
            this.loadError = this.errorMessage(e);
        } finally {
            this.loading = false;
        }
    }

    async handleTest() {
        this.testing = true;
        this.testResult = undefined;
        try {
            this.testResult = await testConnection();
        } catch (e) {
            this.testResult = { ok: false, statusCode: 0, body: this.errorMessage(e) };
        } finally {
            this.testing = false;
        }
    }

    get preLoginLabel() {
        return this.cfg && this.cfg.preLoginCheckEnabled ? 'Enabled' : 'Disabled';
    }

    get setupLabel() {
        return this.cfg && this.cfg.hasConfigRecord ? 'Edit in Setup' : 'Create in Setup';
    }

    get credentialLabel() {
        const status = this.cfg && this.cfg.credentialStatus;
        if (status === 'Configured') return 'Set';
        if (status === 'NotConfigured') return 'Not set';
        return 'Unknown';
    }

    get credentialBadgeClass() {
        const status = this.cfg && this.cfg.credentialStatus;
        return this.badgeClass(status === 'Configured', status === 'NotConfigured');
    }

    get testLabel() {
        if (!this.testResult) return 'Not run yet';
        return `${this.testResult.ok ? 'Passed' : 'Failed'} (HTTP ${this.testResult.statusCode})`;
    }

    get testBadgeClass() {
        return this.badgeClass(this.testResult && this.testResult.ok, this.testResult && !this.testResult.ok);
    }

    badgeClass(good, bad) {
        const theme = good ? ' slds-theme_success' : bad ? ' slds-theme_error' : '';
        return `slds-badge slds-m-left_x-small${theme}`;
    }

    get testResultClass() {
        const theme = this.testResult && this.testResult.ok ? 'slds-theme_success' : 'slds-theme_error';
        return `slds-box slds-box_small slds-m-top_medium ${theme}`;
    }

    errorMessage(e) {
        if (!e) return 'Unknown error';
        if (e.body && e.body.message) return e.body.message;
        if (e.message) return e.message;
        return JSON.stringify(e);
    }
}
