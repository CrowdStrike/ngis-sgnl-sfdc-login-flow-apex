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
 * "<orgid>_search" goes to the asset search route and "<orgid>_evaluate" to
 * the access evaluation route. Neither route has a transform, so both return
 * SGNL's own responses: { decisions, nextPageToken } for search and
 * { decisions } for evaluation.
 */
public with sharing class SgnlClient {

    public static final String  NAMED_CREDENTIAL = 'NGIS_SGNL_Access';
    public static final String  PATH             = '/v1/providers';
    public static final Integer TIMEOUT_MS       = 10000;

    // SGNL accepts 1 to 20 queries per evaluation request
    public static final Integer MAX_EVALUATION_QUERIES = 20;

    // applicationIdPath the provider hook must use to match routing keys
    public static final String ROUTING_KEY_PATH  = '{$.context.routingKey}';

    // The one action the flow sends for permission sets: the search asks which
    // sets it would allow, and submit evaluates it for each selected set.
    public static final String ACTION_ACTIVATE = 'activate';

    // Callout time a transaction may use (the platform limit is 120 s), with
    // room left so the page can still render an error.
    @TestVisible private static Long calloutBudgetMs = 110000;

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
    // properties (org, assetAttributes, evaluationDuration, issuedAt, ...) are
    // tolerated.

    public class SearchDecision {
        public String assetId;
        public String action;
        public String decision;
    }

    // One page of SGNL's asset search response. The provider route doesn't
    // pass paging parameters, so a non-blank nextPageToken means SGNL had more
    // allowed assets than this page holds.
    public class SearchResponse {
        public List<SearchDecision> decisions;
        public String               nextPageToken;
        public String               principalId;
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

    /**
     * One page of the permission sets SGNL would allow principalId to assume:
     * an activate search with no assetId.
     */
    public static SearchResponse searchPermissionSets(String principalId, String routingKey) {
        HttpResponse res = sendChecked(principalId, routingKey, new List<Query>{
            new Query(ACTION_ACTIVATE, null)
        });
        return (SearchResponse) parse(res, SearchResponse.class);
    }

    /**
     * The asset ids in a search response that SGNL allowed for action, in
     * response order. A decision is kept only if it is Allow, its action is
     * the requested one or absent, and it has an asset id. Duplicates are
     * kept; callers that convert to Ids de-duplicate.
     */
    public static List<String> allowedAssetIds(SearchResponse res, String action) {
        List<String> ids = new List<String>();
        if (res == null || res.decisions == null) {
            return ids;
        }
        for (SearchDecision d : res.decisions) {
            if (d == null || d.decision == null || !d.decision.equalsIgnoreCase('Allow')) {
                continue;
            }
            if (String.isNotBlank(d.action) && !d.action.equalsIgnoreCase(action)) {
                continue;
            }
            if (String.isBlank(d.assetId)) {
                continue;
            }
            ids.add(d.assetId);
        }
        return ids;
    }

    public static EvaluateResponse evaluate(String principalId, String routingKey, List<Query> queries) {
        HttpResponse res = sendChecked(principalId, routingKey, queries);
        return (EvaluateResponse) parse(res, EvaluateResponse.class);
    }

    /**
     * Evaluates queries in batches of MAX_EVALUATION_QUERIES and returns true
     * only if allAllowed() accepts every batch. Stops at the first rejected
     * batch. Throws SgnlException rather than start a batch that could run
     * past the transaction's callout limit or callout time limit.
     */
    public static Boolean allAllowedInBatches(String principalId, String routingKey, List<Query> queries) {
        if (queries == null || queries.isEmpty()) {
            return false;
        }
        Long started = System.currentTimeMillis();
        for (Integer first = 0; first < queries.size(); first += MAX_EVALUATION_QUERIES) {
            if (Limits.getCallouts() >= Limits.getLimitCallouts()) {
                throw new SgnlException('SGNL evaluation stopped before the callout limit');
            }
            if (System.currentTimeMillis() - started + TIMEOUT_MS > calloutBudgetMs) {
                throw new SgnlException('SGNL evaluation stopped before the callout time limit');
            }
            List<Query> batch = new List<Query>();
            Integer last = Math.min(first + MAX_EVALUATION_QUERIES, queries.size());
            for (Integer i = first; i < last; i++) {
                batch.add(queries[i]);
            }
            if (!allAllowed(batch, evaluate(principalId, routingKey, batch))) {
                return false;
            }
        }
        return true;
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
