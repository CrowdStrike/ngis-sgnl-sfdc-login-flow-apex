/**
 * Client for the SGNL access API, reached through the CrowdStrike authorizer.
 *
 * Every call is POST /v1/providers through the NGIS_SGNL_Access Named
 * Credential. Salesforce fetches and caches the Falcon OAuth2
 * client-credentials token through the NGIS_SGNL_Falcon_OAuth External
 * Credential, so no token handling happens here.
 *
 * context.org is the plain 15-char Org Id, so policies see the real value.
 * The tenant's SGNL provider hook routes on context.routingKey:
 * "<orgid>_search" goes to a search route whose transform returns
 * { decision, permissionSetIds }, and "<orgid>_evaluate" goes to the access
 * evaluation route, which returns { decisions: [...] }.
 */
public with sharing class SgnlClient {

    public static final String  NAMED_CREDENTIAL = 'NGIS_SGNL_Access';
    public static final String  PATH             = '/v1/providers';
    public static final Integer TIMEOUT_MS       = 10000;

    // applicationIdPath the provider hook must use to match routing keys
    public static final String ROUTING_KEY_PATH  = '{$.context.routingKey}';

    public static final String ACTION_LIST_PERMISSION_SETS = 'listPermissionSets';
    public static final String ACTION_ASSUME_PERMISSION_SET = 'assumePermissionSet';

    public class SgnlException extends Exception {}

    // ---------------- Request shapes ----------------

    public class Query {
        public String action;
        public String assetId;

        public Query(String action, String assetId) {
            this.action  = action;
            this.assetId = assetId;
        }
    }

    public class Principal {
        public String id;
    }

    public class Context {
        public String org;
        public String routingKey;
    }

    public class Request {
        public Principal   principal;
        public List<Query> queries;
        public Context     context;
    }

    // ---------------- Response shapes ----------------
    // JSON.deserialize ignores fields not declared here, so SGNL's additional
    // properties (org, evaluationDuration, issuedAt, ...) are tolerated.

    // Shape produced by the tenant's search transform, not an SGNL type.
    public class ListResponse {
        public String       decision;
        public List<String> permissionSetIds;

        public Boolean isAllowed() {
            return decision != null && decision.equalsIgnoreCase('allow');
        }
    }

    public class EvaluationDecision {
        public String       action;
        public String       assetId;
        public String       decision;
        public List<String> reasons;
    }

    public class EvaluateResponse {
        public List<EvaluationDecision> decisions;
        public String                   principalId;
    }

    // ---------------- Public API ----------------

    /**
     * The principal.id sent to SGNL for the running user. Every caller goes
     * through here so the identifier can change in one place.
     */
    public static String currentPrincipalId() {
        return UserInfo.getUserName();
    }

    /**
     * The context.org sent to SGNL: the running org's 15-char Id. Routing
     * keys use the same prefix (see LoginFlowConfig).
     */
    public static String currentOrgId() {
        return UserInfo.getOrganizationId().left(15);
    }

    /**
     * Raw POST. Throws CalloutException on network or token-fetch failure;
     * does not inspect the response. Used by the admin Test Connection.
     */
    public static HttpResponse send(String principalId, String routingKey, List<Query> queries) {
        Request body = new Request();
        body.principal          = new Principal();
        body.principal.id       = principalId;
        body.queries            = queries;
        body.context            = new Context();
        body.context.org        = currentOrgId();
        body.context.routingKey = routingKey;

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + NAMED_CREDENTIAL + PATH);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        // suppressApexObjectNulls: omit "assetId": null on action-only queries
        req.setBody(JSON.serialize(body, true));
        req.setTimeout(TIMEOUT_MS);
        return new Http().send(req);
    }

    public static ListResponse listPermissionSets(String principalId, String routingKey) {
        HttpResponse res = sendChecked(principalId, routingKey, new List<Query>{
            new Query(ACTION_LIST_PERMISSION_SETS, null)
        });
        return (ListResponse) parse(res, ListResponse.class);
    }

    public static EvaluateResponse evaluate(String principalId, String routingKey, List<Query> queries) {
        HttpResponse res = sendChecked(principalId, routingKey, queries);
        return (EvaluateResponse) parse(res, EvaluateResponse.class);
    }

    /**
     * True only if SGNL returned exactly one Allow decision per requested
     * query, in order. When a decision echoes action or assetId, it must match
     * the query at the same index.
     */
    public static Boolean allAllowed(List<Query> requested, EvaluateResponse res) {
        if (requested == null || requested.isEmpty() || res == null || res.decisions == null) {
            return false;
        }
        if (res.decisions.size() != requested.size()) {
            return false;
        }
        for (Integer i = 0; i < requested.size(); i++) {
            Query q = requested[i];
            EvaluationDecision d = res.decisions[i];
            if (d == null || d.decision == null || !d.decision.equalsIgnoreCase('Allow')) {
                return false;
            }
            if (String.isNotBlank(d.action) && !d.action.equalsIgnoreCase(q.action)) {
                return false;
            }
            if (String.isNotBlank(d.assetId) && !sameAssetId(q.assetId, d.assetId)) {
                return false;
            }
        }
        return true;
    }

    // ---------------- Internals ----------------

    private static HttpResponse sendChecked(String principalId, String routingKey, List<Query> queries) {
        HttpResponse res;
        try {
            res = send(principalId, routingKey, queries);
        } catch (CalloutException e) {
            throw new SgnlException('SGNL callout failed: ' + e.getMessage(), e);
        }
        Integer code = res.getStatusCode();
        if (code < 200 || code > 299) {
            throw new SgnlException('SGNL returned HTTP ' + code);
        }
        if (String.isBlank(res.getBody())) {
            throw new SgnlException('SGNL returned an empty body');
        }
        return res;
    }

    private static Object parse(HttpResponse res, Type responseType) {
        Object parsed;
        try {
            parsed = JSON.deserialize(res.getBody(), responseType);
        } catch (JSONException e) {
            throw new SgnlException('SGNL returned malformed JSON: ' + e.getMessage(), e);
        }
        if (parsed == null) {
            throw new SgnlException('SGNL returned an empty body');
        }
        return parsed;
    }

    // Salesforce Ids compare as Id so 15- and 18-char forms match; anything
    // else must match exactly.
    private static Boolean sameAssetId(String expected, String actual) {
        if (String.isBlank(expected)) {
            return false;
        }
        if (expected.equals(actual)) {
            return true;
        }
        try {
            return Id.valueOf(expected) == Id.valueOf(actual);
        } catch (StringException e) {
            return false;
        }
    }
}
