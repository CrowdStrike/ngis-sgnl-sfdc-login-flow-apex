@IsTest
private class SgnlClientTest {

    // Returns a fixed status/body, or throws CalloutException, and records the
    // request it received.
    private class Mock implements HttpCalloutMock {
        private final Integer status;
        private final String  body;
        private final Boolean throwCallout;
        public HttpRequest lastRequest;

        Mock(Integer status, String body) {
            this.status       = status;
            this.body         = body;
            this.throwCallout = false;
        }

        Mock(Boolean throwCallout) {
            this.status       = null;
            this.body         = null;
            this.throwCallout = throwCallout;
        }

        public HttpResponse respond(HttpRequest req) {
            lastRequest = req;
            if (throwCallout) {
                throw new CalloutException('Read timed out');
            }
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            if (body != null) {
                res.setBody(body);
            }
            return res;
        }
    }

    // Returns 200 with the given bodies in order and records every request
    private class SequenceMock implements HttpCalloutMock {
        private final List<String> bodies;
        public List<HttpRequest> requests = new List<HttpRequest>();

        SequenceMock(List<String> bodies) {
            this.bodies = bodies;
        }

        public HttpResponse respond(HttpRequest req) {
            requests.add(req);
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(bodies[Math.min(requests.size(), bodies.size()) - 1]);
            return res;
        }
    }

    private static final String PS_15  = '0PS000000000001';
    private static final String ASSUME = SgnlClient.ACTION_ASSUME_PERMISSION_SET;

    // Not named "json": Apex is case-insensitive, so that would hide the JSON class
    private static SgnlClient.EvaluateResponse evalResponse(String body) {
        return (SgnlClient.EvaluateResponse) JSON.deserialize(body, SgnlClient.EvaluateResponse.class);
    }

    private static SgnlClient.SearchResponse searchResponse(String body) {
        return (SgnlClient.SearchResponse) JSON.deserialize(body, SgnlClient.SearchResponse.class);
    }

    // One search page allowing each id; token == null means the last page
    private static String page(List<String> ids, String token) {
        List<Object> decisions = new List<Object>();
        for (String psId : ids) {
            decisions.add(new Map<String, Object>{ 'assetId' => psId, 'action' => ASSUME, 'decision' => 'Allow' });
        }
        Map<String, Object> body = new Map<String, Object>{ 'decisions' => decisions };
        if (token != null) {
            body.put('nextPageToken', token);
        }
        return JSON.serialize(body);
    }

    private static List<SgnlClient.Query> assumeQueries(Integer count) {
        List<SgnlClient.Query> qs = new List<SgnlClient.Query>();
        for (Integer i = 1; i <= count; i++) {
            qs.add(new SgnlClient.Query(ASSUME, '0PS' + String.valueOf(i).leftPad(12, '0')));
        }
        return qs;
    }

    private static List<SgnlClient.Query> assumeQueries(List<String> ids) {
        List<SgnlClient.Query> qs = new List<SgnlClient.Query>();
        for (String psId : ids) {
            qs.add(new SgnlClient.Query(ASSUME, psId));
        }
        return qs;
    }

    // An evaluation response allowing every query in the request
    private static String allowAll(Integer count) {
        List<Object> decisions = new List<Object>();
        for (Integer i = 0; i < count; i++) {
            decisions.add(new Map<String, Object>{ 'decision' => 'Allow' });
        }
        return JSON.serialize(new Map<String, Object>{ 'decisions' => decisions });
    }

    private static Integer queryCount(HttpRequest req) {
        return ((List<Object>) ((Map<String, Object>) JSON.deserializeUntyped(req.getBody())).get('queries')).size();
    }

    private static void assertSearchThrows(Mock m, String expectedFragment) {
        Test.setMock(HttpCalloutMock.class, m);
        try {
            SgnlClient.search('alice@example.com', ASSUME, null);
            Assert.fail('Expected SgnlException');
        } catch (SgnlClient.SgnlException e) {
            Assert.isTrue(e.getMessage().contains(expectedFragment), e.getMessage());
        }
    }

    private static void assertBody(HttpRequest req, String expectedAction, Boolean expectAssetId) {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
        Map<String, Object> principal = (Map<String, Object>) body.get('principal');
        Map<String, Object> context = (Map<String, Object>) body.get('context');
        Map<String, Object> query = (Map<String, Object>) ((List<Object>) body.get('queries'))[0];
        Assert.areEqual('alice@example.com', principal.get('id'));
        Assert.areEqual(new Set<String>{ 'orgId' }, context.keySet(), 'context carries only orgId');
        Assert.areEqual(UserInfo.getOrganizationId().left(15), context.get('orgId'), 'orgId must be the plain 15-char Org Id');
        Assert.areEqual(expectedAction, query.get('action'));
        Assert.areEqual(expectAssetId, query.containsKey('assetId'), 'Null assetId must be omitted');
    }

    // ---------------- Identity ----------------

    @IsTest
    static void currentPrincipalId_isUsername() {
        Assert.areEqual(UserInfo.getUserName(), SgnlClient.currentPrincipalId());
    }

    @IsTest
    static void currentOrgId_isFifteenChars() {
        Assert.areEqual(UserInfo.getOrganizationId().left(15), SgnlClient.currentOrgId());
    }

    // ---------------- search (one page) ----------------

    @IsTest
    static void search_sendsExpectedRequest() {
        Mock m = new Mock(200, '{"decisions":[]}');
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        SgnlClient.search('alice@example.com', ASSUME, null);
        Test.stopTest();

        Assert.areEqual('callout:NGIS_SGNL_Access/v1/search/assets?pageSize=200', m.lastRequest.getEndpoint());
        Assert.areEqual('POST', m.lastRequest.getMethod());
        assertBody(m.lastRequest, ASSUME, false);
    }

    @IsTest
    static void search_withPageToken_urlEncodesIt() {
        Mock m = new Mock(200, '{"decisions":[]}');
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        SgnlClient.search('alice@example.com', ASSUME, 'a+b/c=');
        Test.stopTest();

        Assert.areEqual('callout:NGIS_SGNL_Access/v1/search/assets?pageSize=200&pageToken=a%2Bb%2Fc%3D', m.lastRequest.getEndpoint());
    }

    @IsTest
    static void search_parsesNativeResponse() {
        Test.setMock(HttpCalloutMock.class, new Mock(200,
            '{"decisions":[{"assetId":"' + PS_15 + '","action":"assumePermissionSet","decision":"Allow",'
            + '"assetAttributes":{"id":"' + PS_15 + '","name":"Elevated","hasActivationRequired":true}}],'
            + '"nextPageToken":"abc","principalId":"alice@example.com","issuedAt":"2026-01-01T00:00:00Z","evaluationDuration":7}'));

        Test.startTest();
        SgnlClient.SearchResponse res = SgnlClient.search('alice@example.com', ASSUME, null);
        Test.stopTest();

        Assert.areEqual(1, res.decisions.size());
        Assert.areEqual(PS_15, res.decisions[0].assetId);
        Assert.areEqual('abc', res.nextPageToken);
    }

    @IsTest
    static void search_unauthorized_throws() {
        assertSearchThrows(new Mock(401, '{"error":"unauthorized"}'), 'HTTP 401');
    }

    @IsTest
    static void search_serverError_throws() {
        assertSearchThrows(new Mock(500, 'oops'), 'HTTP 500');
    }

    @IsTest
    static void search_emptyBody_throws() {
        assertSearchThrows(new Mock(200, null), 'empty body');
    }

    @IsTest
    static void search_malformedJson_throws() {
        assertSearchThrows(new Mock(200, '<html>login</html>'), 'malformed JSON');
    }

    @IsTest
    static void search_calloutException_isWrapped() {
        assertSearchThrows(new Mock(true), 'Read timed out');
    }

    // ---------------- searchAllowedAssetIds (paging) ----------------

    @IsTest
    static void searchAllowedAssetIds_followsPagesWithTheSameBody() {
        SequenceMock m = new SequenceMock(new List<String>{ page(new List<String>{ 'A' }, 't1'), page(new List<String>{ 'B' }, null) });
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        SgnlClient.SearchResult r = SgnlClient.searchAllowedAssetIds('alice@example.com', ASSUME);
        Test.stopTest();

        Assert.areEqual(new List<String>{ 'A', 'B' }, r.assetIds);
        Assert.isFalse(r.truncated);
        Assert.areEqual(2, m.requests.size());
        Assert.isTrue(m.requests[1].getEndpoint().endsWith('&pageToken=t1'), m.requests[1].getEndpoint());
        Assert.areEqual(m.requests[0].getBody(), m.requests[1].getBody(), 'The page token is tied to the request body');
    }

    @IsTest
    static void searchAllowedAssetIds_readsEveryPageUntilThereIsNoToken() {
        List<String> bodies = new List<String>();
        for (Integer i = 1; i <= 7; i++) {
            bodies.add(page(new List<String>{ 'P' + i }, i < 7 ? 't' + i : null));
        }
        SequenceMock m = new SequenceMock(bodies);
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        SgnlClient.SearchResult r = SgnlClient.searchAllowedAssetIds('alice@example.com', ASSUME);
        Test.stopTest();

        Assert.areEqual(7, m.requests.size());
        Assert.areEqual(7, r.assetIds.size());
        Assert.isFalse(r.truncated);
    }

    @IsTest
    static void searchAllowedAssetIds_stopsBeforeTheCalloutLimit() {
        // Every page says there is another, so only the platform limit ends the loop
        SequenceMock m = new SequenceMock(new List<String>{ page(new List<String>{ 'A' }, 'more') });
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        SgnlClient.SearchResult r = SgnlClient.searchAllowedAssetIds('alice@example.com', ASSUME);
        Test.stopTest();

        Assert.areEqual(Limits.getLimitCallouts(), m.requests.size());
        Assert.isTrue(r.truncated);
        Assert.areEqual('callout limit', r.truncatedReason);
    }

    @IsTest
    static void searchAllowedAssetIds_stopsBeforeTheHeapLimit() {
        SequenceMock m = new SequenceMock(new List<String>{ page(new List<String>{ 'A' }, 'more') });
        Test.setMock(HttpCalloutMock.class, m);
        // Allow no heap at all, so the search stops once the first page is read
        SgnlClient.heapFractionLimit = 0;

        Test.startTest();
        SgnlClient.SearchResult r = SgnlClient.searchAllowedAssetIds('alice@example.com', ASSUME);
        Test.stopTest();

        Assert.areEqual(1, m.requests.size(), 'The first page is always read');
        Assert.isTrue(r.truncated);
        Assert.areEqual('heap size limit', r.truncatedReason);
    }

    @IsTest
    static void searchAllowedAssetIds_stopsBeforeTheCalloutTimeLimit() {
        SequenceMock m = new SequenceMock(new List<String>{ page(new List<String>{ 'A' }, 'more') });
        Test.setMock(HttpCalloutMock.class, m);
        // The search keeps one callout's time free for the pre-login check, so this leaves it none
        SgnlClient.calloutBudgetMs = SgnlClient.TIMEOUT_MS;

        Test.startTest();
        SgnlClient.SearchResult r = SgnlClient.searchAllowedAssetIds('alice@example.com', ASSUME);
        Test.stopTest();

        Assert.areEqual(1, m.requests.size(), 'The first page is always read');
        Assert.areEqual(new List<String>{ 'A' }, r.assetIds);
        Assert.isTrue(r.truncated);
        Assert.areEqual('callout time limit', r.truncatedReason);
    }

    @IsTest
    static void searchAllowedAssetIds_continuesPastEmptyPage() {
        Test.setMock(HttpCalloutMock.class, new SequenceMock(new List<String>{
            page(new List<String>(), 't1'), page(new List<String>{ 'B' }, null)
        }));

        Test.startTest();
        SgnlClient.SearchResult r = SgnlClient.searchAllowedAssetIds('alice@example.com', ASSUME);
        Test.stopTest();

        Assert.areEqual(new List<String>{ 'B' }, r.assetIds);
        Assert.isFalse(r.truncated);
    }

    // ---------------- allowedAssetIds ----------------

    @IsTest
    static void allowedAssetIds_keepsAllowedMatchingDecisions() {
        SgnlClient.SearchResponse res = searchResponse('{"decisions":['
            + '{"assetId":"A","action":"assumePermissionSet","decision":"Allow"},'
            + '{"assetId":"B","action":"assumePermissionSet","decision":"Deny"},'
            + '{"assetId":"C","action":"listPermissionSets","decision":"Allow"},'
            + '{"assetId":"D","decision":"allow"},'
            + '{"action":"assumePermissionSet","decision":"Allow"},'
            + '{"assetId":" ","decision":"Allow"},'
            + '{"assetId":"E","action":"assumePermissionSet"}]}');
        // JSON.deserialize rejects a null list element, so add one directly
        res.decisions.add(null);

        Assert.areEqual(new List<String>{ 'A', 'D' }, SgnlClient.allowedAssetIds(res, ASSUME));
    }

    @IsTest
    static void allowedAssetIds_nullOrEmpty_returnsEmpty() {
        Assert.areEqual(0, SgnlClient.allowedAssetIds(null, ASSUME).size());
        Assert.areEqual(0, SgnlClient.allowedAssetIds(searchResponse('{}'), ASSUME).size());
        Assert.areEqual(0, SgnlClient.allowedAssetIds(searchResponse('{"decisions":null}'), ASSUME).size());
        Assert.areEqual(0, SgnlClient.allowedAssetIds(searchResponse('{"decisions":[]}'), ASSUME).size());
    }

    // ---------------- evaluate ----------------

    @IsTest
    static void evaluate_sendsExpectedRequest() {
        Mock m = new Mock(200, '{"decisions":[{"action":"assumePermissionSet","assetId":"' + PS_15 + '","decision":"Allow"}]}');
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        SgnlClient.evaluate('alice@example.com', assumeQueries(new List<String>{ PS_15 }));
        Test.stopTest();

        Assert.areEqual('callout:NGIS_SGNL_Access/v1/evaluations', m.lastRequest.getEndpoint());
        Assert.areEqual('POST', m.lastRequest.getMethod());
        assertBody(m.lastRequest, ASSUME, true);
    }

    @IsTest
    static void evaluate_success() {
        Test.setMock(HttpCalloutMock.class, new Mock(200, '{"decisions":[{"action":"login","decision":"Allow","orgId":"00D000000000001"}],"evaluationDuration":3}'));
        List<SgnlClient.Query> qs = new List<SgnlClient.Query>{ new SgnlClient.Query('login', null) };

        Test.startTest();
        SgnlClient.EvaluateResponse res = SgnlClient.evaluate('alice@example.com', qs);
        Test.stopTest();

        Assert.areEqual(1, res.decisions.size());
        Assert.isTrue(SgnlClient.allAllowed(qs, res));
    }

    @IsTest
    static void evaluate_wrongJsonType_throws() {
        Test.setMock(HttpCalloutMock.class, new Mock(200, '{"decisions":"nope"}'));
        try {
            SgnlClient.evaluate('alice@example.com', assumeQueries(new List<String>{ PS_15 }));
            Assert.fail('Expected SgnlException');
        } catch (SgnlClient.SgnlException e) {
            Assert.isTrue(e.getMessage().contains('malformed JSON'), e.getMessage());
        }
    }

    // ---------------- allAllowedInBatches ----------------

    @IsTest
    static void allAllowedInBatches_sendsBatchesOfTwenty() {
        SequenceMock m = new SequenceMock(new List<String>{ allowAll(20), allowAll(20), allowAll(5) });
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        Boolean approved = SgnlClient.allAllowedInBatches('alice@example.com', assumeQueries(45));
        Test.stopTest();

        Assert.isTrue(approved);
        Assert.areEqual(3, m.requests.size());
        Assert.areEqual(20, queryCount(m.requests[0]));
        Assert.areEqual(20, queryCount(m.requests[1]));
        Assert.areEqual(5, queryCount(m.requests[2]));
        Assert.areEqual('callout:NGIS_SGNL_Access/v1/evaluations', m.requests[2].getEndpoint());
    }

    @IsTest
    static void allAllowedInBatches_stopsAtFirstRejectedBatch() {
        // The second batch gets 19 decisions for 20 queries, which allAllowed rejects
        SequenceMock m = new SequenceMock(new List<String>{ allowAll(20), allowAll(19), allowAll(5) });
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        Boolean approved = SgnlClient.allAllowedInBatches('alice@example.com', assumeQueries(45));
        Test.stopTest();

        Assert.isFalse(approved);
        Assert.areEqual(2, m.requests.size(), 'No batch is sent after a rejected one');
    }

    @IsTest
    static void allAllowedInBatches_stopsBeforeTheCalloutTimeLimit() {
        SequenceMock m = new SequenceMock(new List<String>{ allowAll(1) });
        Test.setMock(HttpCalloutMock.class, m);
        SgnlClient.calloutBudgetMs = 0;

        try {
            SgnlClient.allAllowedInBatches('alice@example.com', assumeQueries(1));
            Assert.fail('Expected SgnlException');
        } catch (SgnlClient.SgnlException e) {
            Assert.isTrue(e.getMessage().contains('callout time limit'), e.getMessage());
        }
        Assert.areEqual(0, m.requests.size());
    }

    @IsTest
    static void allAllowedInBatches_stopsBeforeTheCalloutLimit() {
        // 101 batches of 20 would need more callouts than one transaction may make
        SequenceMock m = new SequenceMock(new List<String>{ allowAll(20) });
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        try {
            SgnlClient.allAllowedInBatches('alice@example.com', assumeQueries(2020));
            Assert.fail('Expected SgnlException');
        } catch (SgnlClient.SgnlException e) {
            Assert.isTrue(e.getMessage().contains('callout limit'), e.getMessage());
        }
        Test.stopTest();

        Assert.areEqual(Limits.getLimitCallouts(), m.requests.size());
    }

    @IsTest
    static void allAllowedInBatches_emptyOrNull_false() {
        Assert.isFalse(SgnlClient.allAllowedInBatches('alice@example.com', new List<SgnlClient.Query>()));
        Assert.isFalse(SgnlClient.allAllowedInBatches('alice@example.com', null));
    }

    // ---------------- send ----------------

    @IsTest
    static void send_returnsRawResponseWithoutChecking() {
        Mock m = new Mock(403, 'forbidden');
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        HttpResponse res = SgnlClient.send(SgnlClient.SEARCH_ENDPOINT, 'alice@example.com',
            new List<SgnlClient.Query>{ new SgnlClient.Query(ASSUME, null) });
        Test.stopTest();

        Assert.areEqual(403, res.getStatusCode());
        Assert.areEqual('callout:NGIS_SGNL_Access/v1/search/assets?pageSize=200', m.lastRequest.getEndpoint());
    }

    // ---------------- allAllowed ----------------

    @IsTest
    static void allAllowed_matchingDecisions_true() {
        List<SgnlClient.Query> qs = assumeQueries(new List<String>{ PS_15, '0PS000000000002' });
        SgnlClient.EvaluateResponse res = evalResponse(
            '{"decisions":[' +
            '{"action":"assumePermissionSet","assetId":"' + PS_15 + '","decision":"Allow"},' +
            '{"action":"assumePermissionSet","assetId":"0PS000000000002","decision":"Allow"}]}'
        );
        Assert.isTrue(SgnlClient.allAllowed(qs, res));
    }

    @IsTest
    static void allAllowed_fewerDecisionsThanQueries_false() {
        List<SgnlClient.Query> qs = assumeQueries(new List<String>{ PS_15, '0PS000000000002' });
        SgnlClient.EvaluateResponse res = evalResponse('{"decisions":[{"decision":"Allow"}]}');
        Assert.isFalse(SgnlClient.allAllowed(qs, res));
    }

    @IsTest
    static void allAllowed_moreDecisionsThanQueries_false() {
        List<SgnlClient.Query> qs = assumeQueries(new List<String>{ PS_15 });
        SgnlClient.EvaluateResponse res = evalResponse('{"decisions":[{"decision":"Allow"},{"decision":"Allow"}]}');
        Assert.isFalse(SgnlClient.allAllowed(qs, res));
    }

    @IsTest
    static void allAllowed_mixedDecisions_false() {
        List<SgnlClient.Query> qs = assumeQueries(new List<String>{ PS_15, '0PS000000000002' });
        SgnlClient.EvaluateResponse res = evalResponse('{"decisions":[{"decision":"Allow"},{"decision":"Deny"}]}');
        Assert.isFalse(SgnlClient.allAllowed(qs, res));
    }

    @IsTest
    static void allAllowed_assetIdMismatch_false() {
        List<SgnlClient.Query> qs = assumeQueries(new List<String>{ PS_15 });
        SgnlClient.EvaluateResponse res = evalResponse('{"decisions":[{"assetId":"0PS000000000009","decision":"Allow"}]}');
        Assert.isFalse(SgnlClient.allAllowed(qs, res));
    }

    @IsTest
    static void allAllowed_actionMismatch_false() {
        List<SgnlClient.Query> qs = assumeQueries(new List<String>{ PS_15 });
        SgnlClient.EvaluateResponse res = evalResponse('{"decisions":[{"action":"login","decision":"Allow"}]}');
        Assert.isFalse(SgnlClient.allAllowed(qs, res));
    }

    @IsTest
    static void allAllowed_fifteenVsEighteenCharId_true() {
        String eighteen = String.valueOf(Id.valueOf(PS_15));
        List<SgnlClient.Query> qs = assumeQueries(new List<String>{ PS_15 });
        SgnlClient.EvaluateResponse res = evalResponse('{"decisions":[{"assetId":"' + eighteen + '","decision":"Allow"}]}');
        Assert.isTrue(SgnlClient.allAllowed(qs, res));
    }

    @IsTest
    static void allAllowed_decisionWithoutActionOrAssetId_true() {
        List<SgnlClient.Query> qs = assumeQueries(new List<String>{ PS_15 });
        SgnlClient.EvaluateResponse res = evalResponse('{"decisions":[{"decision":"allow"}]}');
        Assert.isTrue(SgnlClient.allAllowed(qs, res));
    }

    @IsTest
    static void allAllowed_preflightWithoutAssetId_true() {
        List<SgnlClient.Query> qs = new List<SgnlClient.Query>{ new SgnlClient.Query('login', null) };
        SgnlClient.EvaluateResponse res = evalResponse('{"decisions":[{"action":"login","decision":"Allow"}]}');
        Assert.isTrue(SgnlClient.allAllowed(qs, res));
    }

    @IsTest
    static void allAllowed_assetIdEchoedForActionOnlyQuery_false() {
        List<SgnlClient.Query> qs = new List<SgnlClient.Query>{ new SgnlClient.Query('login', null) };
        SgnlClient.EvaluateResponse res = evalResponse('{"decisions":[{"assetId":"something","decision":"Allow"}]}');
        Assert.isFalse(SgnlClient.allAllowed(qs, res));
    }

    @IsTest
    static void allAllowed_missingDecisionValue_false() {
        List<SgnlClient.Query> qs = assumeQueries(new List<String>{ PS_15 });
        Assert.isFalse(SgnlClient.allAllowed(qs, evalResponse('{"decisions":[{}]}')));
    }

    @IsTest
    static void allAllowed_nullOrEmptyInputs_false() {
        List<SgnlClient.Query> qs = assumeQueries(new List<String>{ PS_15 });
        Assert.isFalse(SgnlClient.allAllowed(qs, null));
        Assert.isFalse(SgnlClient.allAllowed(qs, evalResponse('{}')));
        Assert.isFalse(SgnlClient.allAllowed(qs, evalResponse('{"decisions":[]}')));
        Assert.isFalse(SgnlClient.allAllowed(new List<SgnlClient.Query>(), evalResponse('{"decisions":[]}')));
        Assert.isFalse(SgnlClient.allAllowed(null, evalResponse('{"decisions":[{"decision":"Allow"}]}')));
    }
}
