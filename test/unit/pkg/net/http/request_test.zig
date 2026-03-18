const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const request = embed.pkg.net.http.request;

test "parse GET request" {
    const raw = "GET /index.html HTTP/1.1\r\nHost: example.com\r\nAccept: text/html\r\n\r\n";
    const result = try request.parse(raw);
    const req = result.request;

    try std.testing.expectEqual(request.Method.GET, req.method);
    try std.testing.expectEqualStrings("/index.html", req.path);
    try std.testing.expect(req.query == null);
    try std.testing.expectEqualStrings("HTTP/1.1", req.version);
    try std.testing.expectEqual(@as(usize, 0), req.content_length);
    try std.testing.expect(req.body == null);
    try std.testing.expectEqualStrings("example.com", req.header("Host").?);
}

test "parse POST request with body" {
    const raw = "POST /api/data HTTP/1.1\r\nHost: api.example.com\r\nContent-Length: 13\r\n\r\nHello, World!";
    const result = try request.parse(raw);
    const req = result.request;

    try std.testing.expectEqual(request.Method.POST, req.method);
    try std.testing.expectEqualStrings("/api/data", req.path);
    try std.testing.expectEqual(@as(usize, 13), req.content_length);
    try std.testing.expectEqualStrings("Hello, World!", req.body.?);
}

test "parse query string" {
    const raw = "GET /search?q=hello&lang=en HTTP/1.1\r\nHost: example.com\r\n\r\n";
    const result = try request.parse(raw);
    const req = result.request;

    try std.testing.expectEqualStrings("/search", req.path);
    try std.testing.expectEqualStrings("q=hello&lang=en", req.query.?);
}

test "header iteration" {
    const raw = "GET / HTTP/1.1\r\nHost: example.com\r\nAccept: text/html\r\nX-Custom: value\r\n\r\n";
    const result = try request.parse(raw);
    const req = result.request;

    var iter = req.headers();
    const h1 = iter.next().?;
    try std.testing.expectEqualStrings("Host", h1.name);
    try std.testing.expectEqualStrings("example.com", h1.value);
    const h2 = iter.next().?;
    try std.testing.expectEqualStrings("Accept", h2.name);
    try std.testing.expectEqualStrings("text/html", h2.value);
    const h3 = iter.next().?;
    try std.testing.expectEqualStrings("X-Custom", h3.name);
    try std.testing.expectEqualStrings("value", h3.value);
    try std.testing.expect(iter.next() == null);
}

test "incomplete request — no header terminator" {
    const raw = "GET /index.html HTTP/1.1\r\nHost: example.com\r\n";
    try std.testing.expectError(error.Incomplete, request.parse(raw));
}

test "incomplete request — body not yet received" {
    const raw = "POST /data HTTP/1.1\r\nContent-Length: 100\r\n\r\nshort";
    try std.testing.expectError(error.Incomplete, request.parse(raw));
}

test "malformed request — invalid method" {
    const raw = "FROBNICATE /path HTTP/1.1\r\nHost: x\r\n\r\n";
    try std.testing.expectError(error.InvalidMethod, request.parse(raw));
}

test "case-insensitive header lookup" {
    const raw = "GET / HTTP/1.1\r\nContent-Type: application/json\r\n\r\n";
    const result = try request.parse(raw);
    try std.testing.expectEqualStrings("application/json", result.request.header("content-type").?);
}

test "writeUsize" {
    var buf: [20]u8 = undefined;
    try std.testing.expectEqualStrings("0", request.writeUsize(&buf, 0).?);
    try std.testing.expectEqualStrings("42", request.writeUsize(&buf, 42).?);
    try std.testing.expectEqualStrings("12345", request.writeUsize(&buf, 12345).?);
}

test "Method.toString round-trip" {
    try std.testing.expectEqualStrings("GET", request.Method.GET.toString());
    try std.testing.expectEqualStrings("POST", request.Method.POST.toString());
    try std.testing.expectEqualStrings("PUT", request.Method.PUT.toString());
    try std.testing.expectEqualStrings("DELETE", request.Method.DELETE.toString());
    try std.testing.expectEqualStrings("HEAD", request.Method.HEAD.toString());
    try std.testing.expectEqualStrings("OPTIONS", request.Method.OPTIONS.toString());
    try std.testing.expectEqualStrings("PATCH", request.Method.PATCH.toString());
}

test "Method.fromString round-trip" {
    inline for (.{ "GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH" }) |s| {
        const m = request.Method.fromString(s).?;
        try std.testing.expectEqualStrings(s, m.toString());
    }
    try std.testing.expect(request.Method.fromString("INVALID") == null);
}
