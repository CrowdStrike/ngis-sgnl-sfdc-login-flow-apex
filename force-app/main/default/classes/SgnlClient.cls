/**
 * Client for the SGNL access API, reached through the CrowdStrike authorizer.
 *
 * Two endpoints, both POST through the NGIS_SGNL_Access Named Credential:
 * /v1/search/assets lists the permission sets the user may assume, and
 * /v1/evaluations checks a selection or the pre-login action. Salesforce
 * fetches and caches the Falcon OAuth2 client-credentials token through the
 * NGIS_SGNL_Falcon_OAuth External Credential, so no token handling happens
 * here.
 *
 * Every request carries context.orgId, the running org's 15-char Id. The
 * tenant's SGNL provider hook matches it ({$.context.orgId}) against its
 * integration assignments to pick this org's Protected System.
 */
public with sharing class SgnlClient {

    public static final String  NAMED_CREDENTIAL = 'NGIS_SGNL_Access';
    public static final String  PATH_EVALUATIONS = '/v1/evaluations';
    public static final String  PATH_SEARCH      = '/v1/search/assets';
    public static final Integer TIMEOUT_MS       = 10000;

    // Search follows every page SGNL returns. It stops early only at an Apex
    // limit (callouts, callout time, heap; see DESIGN.md) and reports why.
    public static final Integer SEARCH_PAGE_SIZE = 200;
    public static final String  SEARCH_ENDPOINT  = PATH_SEARCH + '?pageSize=' + SEARCH_PAGE_SIZE;

    // SGNL accepts 1 to 20 queries per evaluation request
    public static final Integer MAX_EVALUATION_QUERIES = 20;

    // applicationIdPath the provider hook's integration assignment must use
    public static final String APPLICATION_ID_PATH = '{$.context.orgId}';

    public static final String ACTION_ASSUME_PERMISSION_SET = 'assumePermissionSet';

    // Callouts in one transaction share 120 s; batches stop short of that
    @TestVisible private static Long calloutBudgetMs = 110000;

    // The search stops before the heap passes this share of the limit
    @TestVisible private static Decimal heapFractionLimit = 0.8;

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
        public String orgId;
    }

    public class Request {
        public Principal   principal;
        public List<Query> queries;
        public Context     context;
    }

    // ---------------- Response shapes ----------------
    // JSON.deserialize ignores fields not declared here, so SGNL's additional
    // properties (assetAttributes, issuedAt, evaluationDuration, ...) are
    // tolerated and not kept.

    public class SearchDecision {
        public String assetId;
        public String action;
        public String decision;
    }

    public class SearchResponse {
        public List<SearchDecision> decisions;
        public String               nextPageToken;
        public String               principalId;
    }

    // The allowed asset ids from every page read. When an Apex limit stopped
    // the search before the last page, truncated is set and truncatedReason
    // names the limit.
    public class SearchResult {
        public List<String> assetIds        = new List<String>();
        public Boolean      truncated       = false;
        public String       truncatedReason;
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
     * The context.orgId sent to SGNL: the running org's 15-char Id. It is
     * also the application Id on the provider hook's integration assignment.
     */
    public static String currentOrgId() {
        return UserInfo.getOrganizationId().left(15);
    }

    /**
     * Raw POST to path under the Named Credential. Throws CalloutException on
     * network or token-fetch failure; does not inspect the response. Used by
     * the admin Test Connection.
     */
    public static HttpResponse send(String path, String principalId, List<Query> queries) {
        Request body = new Request();
        body.principal     = new Principal();
        body.principal.id  = principalId;
        body.queries       = queries;
        body.context       = new Context();
        body.context.orgId = currentOrgId();

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + NAMED_CREDENTIAL + path);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        // suppressApexObjectNulls: omit "assetId": null on action-only queries
        req.setBody(JSON.serialize(body, true));
        req.setTimeout(TIMEOUT_MS);
        return new Http().send(req);
    }

    /**
     * One page of the assets SGNL allows the principal for action. Pass the
     * previous page's nextPageToken, or null for the first page; the body is
     * the same for every page. SGNL returns only allowed assets.
     */
    public static SearchResponse search(String principalId, String action, String pageToken) {
        String path = SEARCH_ENDPOINT;
        if (String.isNotBlank(pageToken)) {
            path += '&pageToken=' + EncodingUtil.urlEncode(pageToken, 'UTF-8');
        }
        HttpResponse res = sendChecked(path, principalId, new List<Query>{
            new Query(action, null)
        });
        return (SearchResponse) parse(res, SearchResponse.class);
    }

    /**
     * The allowed asset ids from every page SGNL returns, in response order.
     * The first page is always read. Before each later page the search checks
     * the callout count, the callout time and the heap, and stops with
     * truncated set (and truncatedReason) rather than hit an Apex limit that
     * would show a raw error page at login.
     */
    public static SearchResult searchAllowedAssetIds(String principalId, String action) {
        SearchResult result = new SearchResult();
        Long started = System.currentTimeMillis();
        String pageToken = null;
        Boolean firstPage = true;
        while (firstPage || String.isNotBlank(pageToken)) {
            if (!firstPage) {
                String reason = searchStopReason(started);
                if (reason != null) {
                    result.truncated       = true;
                    result.truncatedReason = reason;
                    return result;
                }
            }
            SearchResponse res = search(principalId, action, pageToken);
            result.assetIds.addAll(allowedAssetIds(res, action));
            pageToken = res.nextPageToken;
            firstPage = false;
        }
        return result;
    }

    // The Apex limit that forbids another search callout, or null. The time
    // check keeps one callout's time free for the pre-login check that runs
    // before the search in the same transaction.
    private static String searchStopReason(Long started) {
        if (Limits.getCallouts() >= Limits.getLimitCallouts()) {
            return 'callout limit';
        }
        if (System.currentTimeMillis() - started + TIMEOUT_MS > calloutBudgetMs - TIMEOUT_MS) {
            return 'callout time limit';
        }
        if (Limits.getHeapSize() > Limits.getLimitHeapSize() * heapFractionLimit) {
            return 'heap size limit';
        }
        return null;
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

    public static EvaluateResponse evaluate(String principalId, List<Query> queries) {
        HttpResponse res = sendChecked(PATH_EVALUATIONS, principalId, queries);
        return (EvaluateResponse) parse(res, EvaluateResponse.class);
    }

    /**
     * Evaluates queries in batches of MAX_EVALUATION_QUERIES and returns true
     * only if allAllowed() accepts every batch. Stops at the first rejected
     * batch. Throws SgnlException rather than start a batch that could run
     * past the transaction's callout limit or callout time limit.
     */
    public static Boolean allAllowedInBatches(String principalId, List<Query> queries) {
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
            if (!allAllowed(batch, evaluate(principalId, batch))) {
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

    private static HttpResponse sendChecked(String path, String principalId, List<Query> queries) {
        HttpResponse res;
        try {
            res = send(path, principalId, queries);
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
