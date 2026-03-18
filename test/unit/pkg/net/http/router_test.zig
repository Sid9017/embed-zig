const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const router = embed.pkg.net.http.router;

test "exact match" {
    const routes = [_]router.Route{
        router.get("/api/status", router.dummyHandler),
        router.post("/api/data", router.dummyHandler2),
    };

    const m = router.match(&routes, .GET, "/api/status");
    try testing.expectEqual(router.MatchResult.found, m.result);
    try testing.expect(m.handler != null);
}

test "prefix match" {
    const routes = [_]router.Route{
        router.prefix("/static/", router.dummyHandler),
    };

    const m1 = router.match(&routes, .GET, "/static/app.js");
    try testing.expectEqual(router.MatchResult.found, m1.result);

    const m2 = router.match(&routes, .GET, "/static/css/style.css");
    try testing.expectEqual(router.MatchResult.found, m2.result);

    const m3 = router.match(&routes, .GET, "/api/other");
    try testing.expectEqual(router.MatchResult.not_found, m3.result);
}

test "prefix matches any method" {
    const routes = [_]router.Route{
        router.prefix("/api/", router.dummyHandler),
    };

    try testing.expectEqual(router.MatchResult.found, router.match(&routes, .GET, "/api/foo").result);
    try testing.expectEqual(router.MatchResult.found, router.match(&routes, .POST, "/api/foo").result);
    try testing.expectEqual(router.MatchResult.found, router.match(&routes, .PUT, "/api/foo").result);
    try testing.expectEqual(router.MatchResult.found, router.match(&routes, .DELETE, "/api/foo").result);
}

test "404 no match" {
    const routes = [_]router.Route{
        router.get("/api/status", router.dummyHandler),
    };

    const m = router.match(&routes, .GET, "/unknown");
    try testing.expectEqual(router.MatchResult.not_found, m.result);
    try testing.expect(m.handler == null);
}

test "method mismatch — 405" {
    const routes = [_]router.Route{
        router.get("/api/status", router.dummyHandler),
    };

    const m = router.match(&routes, .POST, "/api/status");
    try testing.expectEqual(router.MatchResult.method_not_allowed, m.result);
    try testing.expect(m.handler == null);
}
