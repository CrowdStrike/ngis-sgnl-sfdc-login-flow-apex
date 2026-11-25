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

    private static final String PS_15 = '0PS000000000001';

    // Not named "json": Apex is case-insensitive, so that would hide the JSON class
    private static SgnlClient.EvaluateResponse evalResponse(String body) {
        return (SgnlClient.EvaluateResponse) JSON.deserialize(body, SgnlClient.EvaluateResponse.class);
    }

    private static List<SgnlClient.Query> assumeQueries(List<String> ids) {
        List<SgnlClient.Query> qs = new List<SgnlClient.Query>();
        for (String psId : ids) {
            qs.add(new SgnlClient.Query(SgnlClient.ACTION_ASSUME_PERMISSION_SET, psId));
        }
        return qs;
    }

    private static void assertListThrows(Mock m, String expectedFragment) {
        Test.setMock(HttpCalloutMock.class, m);
        try {
            SgnlClient.listPermissionSets('alice@example.com', 'org_search');
            Assert.fail('Expected SgnlException');
        } catch (SgnlClient.SgnlException e) {
            Assert.isTrue(e.getMessage().contains(expectedFragment), e.getMessage());
        }
    }

    // ---------------- Calls ----------------

    @IsTest
    static void currentPrincipalId_isUsername() {
        Assert.areEqual(UserInfo.getUserName(), SgnlClient.currentPrincipalId());
    }

    @IsTest
    static void listPermissionSets_success() {
        Mock m = new Mock(200, '{"decisions":[{"assetId":"' + PS_15 + '","action":"listPermissionSets","decision":"Allow"}],'
            + '"nextPageToken":"page-2","principalId":"alice@example.com"}');
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        SgnlClient.SearchResponse res = SgnlClient.listPermissionSets('alice@example.com', 'org_search');
        Test.stopTest();

        Assert.areEqual(1, res.decisions.size());
        Assert.areEqual(PS_15, res.decisions[0].assetId);
        Assert.areEqual('page-2', res.nextPageToken);
        Assert.areEqual(new List<String>{ PS_15 }, SgnlClient.allowedAssetIds(res, SgnlClient.ACTION_LIST_PERMISSION_SETS));
    }

    @IsTest
    static void listPermissionSets_sendsExpectedRequest() {
        Mock m = new Mock(200, '{"decisions":[]}');
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        SgnlClient.listPermissionSets('alice@example.com', 'org_search');
        Test.stopTest();

        Assert.areEqual('callout:NGIS_SGNL_Access/v1/providers', m.lastRequest.getEndpoint());
        Assert.areEqual('POST', m.lastRequest.getMethod());

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(m.lastRequest.getBody());
        Map<String, Object> principal = (Map<String, Object>) body.get('principal');
        Map<String, Object> context = (Map<String, Object>) body.get('context');
        Map<String, Object> query = (Map<String, Object>) ((List<Object>) body.get('queries'))[0];
        Assert.areEqual('alice@example.com', principal.get('id'));
        Assert.areEqual(UserInfo.getOrganizationId().left(15), context.get('org'), 'org must be the plain 15-char Org Id');
        Assert.areEqual('org_search', context.get('routingKey'));
        Assert.areEqual('listPermissionSets', query.get('action'));
        Assert.isFalse(query.containsKey('assetId'), 'Null assetId must be omitted');
    }

    // ---------------- allowedAssetIds ----------------

    private static SgnlClient.SearchResponse searchResponse(String body) {
        return (SgnlClient.SearchResponse) JSON.deserialize(body, SgnlClient.SearchResponse.class);
    }

    @IsTest
    static void allowedAssetIds_keepsAllowInResponseOrder() {
        SgnlClient.SearchResponse res = searchResponse('{"decisions":['
            + '{"assetId":"0PS000000000002","action":"listPermissionSets","decision":"Allow"},'
            + '{"assetId":"' + PS_15 + '","action":"listPermissionSets","decision":"allow"}]}');
        Assert.areEqual(new List<String>{ '0PS000000000002', PS_15 },
            SgnlClient.allowedAssetIds(res, SgnlClient.ACTION_LIST_PERMISSION_SETS));
    }

    @IsTest
    static void allowedAssetIds_dropsDenyBlankAssetIdAndOtherActions() {
        SgnlClient.SearchResponse res = searchResponse('{"decisions":['
            + '{"assetId":"0PS000000000002","action":"listPermissionSets","decision":"Deny"},'
            + '{"action":"listPermissionSets","decision":"Allow"},'
            + '{"assetId":"","action":"listPermissionSets","decision":"Allow"},'
            + '{"assetId":"0PS000000000003","action":"assumePermissionSet","decision":"Allow"},'
            + '{"assetId":"0PS000000000004","action":"listPermissionSets"},'
            + '{"assetId":"' + PS_15 + '","decision":"Allow"}]}');
        Assert.areEqual(new List<String>{ PS_15 },
            SgnlClient.allowedAssetIds(res, SgnlClient.ACTION_LIST_PERMISSION_SETS),
            'Only Allow decisions with an asset id and the requested (or no) action are kept');
    }

    @IsTest
    static void allowedAssetIds_emptyInputs() {
        Assert.areEqual(0, SgnlClient.allowedAssetIds(null, SgnlClient.ACTION_LIST_PERMISSION_SETS).size());
        Assert.areEqual(0, SgnlClient.allowedAssetIds(searchResponse('{}'), SgnlClient.ACTION_LIST_PERMISSION_SETS).size());
        Assert.areEqual(0, SgnlClient.allowedAssetIds(searchResponse('{"decisions":[]}'), SgnlClient.ACTION_LIST_PERMISSION_SETS).size());
    }

    @IsTest
    static void evaluate_success() {
        Mock m = new Mock(200, '{"decisions":[{"action":"login","decision":"Allow","org":"org_evaluate"}],"evaluationDuration":3}');
        Test.setMock(HttpCalloutMock.class, m);
        List<SgnlClient.Query> qs = new List<SgnlClient.Query>{ new SgnlClient.Query('login', null) };

        Test.startTest();
        SgnlClient.EvaluateResponse res = SgnlClient.evaluate('alice@example.com', 'org_evaluate', qs);
        Test.stopTest();

        Assert.areEqual(1, res.decisions.size());
        Assert.isTrue(SgnlClient.allAllowed(qs, res));
    }

    @IsTest
    static void unauthorized_throws() {
        assertListThrows(new Mock(401, '{"error":"unauthorized"}'), 'HTTP 401');
    }

    @IsTest
    static void serverError_throws() {
        assertListThrows(new Mock(500, 'oops'), 'HTTP 500');
    }

    @IsTest
    static void emptyBody_throws() {
        assertListThrows(new Mock(200, null), 'empty body');
    }

    @IsTest
    static void malformedJson_throws() {
        assertListThrows(new Mock(200, '<html>login</html>'), 'malformed JSON');
    }

    @IsTest
    static void wrongJsonType_throws() {
        Test.setMock(HttpCalloutMock.class, new Mock(200, '{"decisions":"nope"}'));
        try {
            SgnlClient.evaluate('alice@example.com', 'org_evaluate', assumeQueries(new List<String>{ PS_15 }));
            Assert.fail('Expected SgnlException');
        } catch (SgnlClient.SgnlException e) {
            Assert.isTrue(e.getMessage().contains('malformed JSON'), e.getMessage());
        }
    }

    @IsTest
    static void calloutException_isWrapped() {
        assertListThrows(new Mock(true), 'Read timed out');
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
