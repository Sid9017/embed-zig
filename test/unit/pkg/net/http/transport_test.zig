const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const transport = embed.pkg.net.http.transport;
const runtime = embed.runtime;
const Std = runtime.std;
const conn_mod = embed.pkg.net.conn;
const tls_mod = embed.pkg.net.tls;
const dns_mod = embed.pkg.net.dns;
const url_mod = embed.pkg.net.url;
const request_mod = embed.pkg.net.http.request;

test "RoundTripper contract with mock" {
    const MockTransport = struct {
        const Self = @This();
        pub fn roundTrip(_: *Self, _: transport.RoundTripRequest, buffer: []u8) transport.TransportError!transport.RoundTripResponse {
            const resp_text = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK";
            @memcpy(buffer[0..resp_text.len], resp_text);
            return transport.parseHttpResponse(buffer, resp_text.len);
        }
    };
    _ = transport.RoundTripper(MockTransport);

    var mock = MockTransport{};
    var buf: [256]u8 = undefined;
    const resp = try mock.roundTrip(.{ .host = "example.com" }, &buf);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqualStrings("OK", resp.body());
}

test "requestFromUrl — HTTP" {
    const req = try transport.requestFromUrl("http://example.com/api/v1?key=val");
    try std.testing.expectEqual(transport.Scheme.http, req.scheme);
    try std.testing.expectEqualStrings("example.com", req.host);
    try std.testing.expectEqual(@as(u16, 80), req.port);
    try std.testing.expectEqualStrings("/api/v1", req.path);
}

test "requestFromUrl — HTTPS with port" {
    const req = try transport.requestFromUrl("https://api.example.com:8443/data");
    try std.testing.expectEqual(transport.Scheme.https, req.scheme);
    try std.testing.expectEqualStrings("api.example.com", req.host);
    try std.testing.expectEqual(@as(u16, 8443), req.port);
    try std.testing.expectEqualStrings("/data", req.path);
}

test "requestFromUrl — HTTPS default port" {
    const req = try transport.requestFromUrl("https://secure.example.com/");
    try std.testing.expectEqual(transport.Scheme.https, req.scheme);
    try std.testing.expectEqual(@as(u16, 443), req.port);
}

test "requestFromUrl — no path" {
    const req = try transport.requestFromUrl("http://example.com");
    try std.testing.expectEqualStrings("/", req.path);
}

test "requestFromUrl — empty host" {
    try std.testing.expectError(error.InvalidUrl, transport.requestFromUrl("http:///path"));
}

test "buildHttpRequest — GET" {
    var buf: [2048]u8 = undefined;
    const len = try transport.buildHttpRequest(&buf, .{
        .host = "example.com",
        .path = "/api",
    });
    const req = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, req, "GET /api HTTP/1.1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Host: example.com\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Connection: close\r\n") != null);
}

test "buildHttpRequest — POST with body" {
    var buf: [2048]u8 = undefined;
    const len = try transport.buildHttpRequest(&buf, .{
        .method = .POST,
        .host = "api.example.com",
        .path = "/submit",
        .body = "hello",
        .content_type = "text/plain",
    });
    const req = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, req, "POST /submit HTTP/1.1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Content-Length: 5\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Content-Type: text/plain\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, req, "hello"));
}

test "findHeaderEnd" {
    const data = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\nBody";
    const end = transport.findHeaderEnd(data).?;
    try std.testing.expectEqual(@as(usize, 44), end);
    try std.testing.expectEqualStrings("Body", data[end..]);
}

test "findHeaderEnd — incomplete" {
    try std.testing.expect(transport.findHeaderEnd("HTTP/1.1 200 OK\r\n") == null);
}

test "parseContentLength" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Length: 1234\r\n\r\n";
    try std.testing.expectEqual(@as(usize, 1234), transport.parseContentLength(headers).?);
}

test "parseContentLength — absent" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n";
    try std.testing.expect(transport.parseContentLength(headers) == null);
}

test "parseHttpResponse — 200 OK" {
    var buffer: [256]u8 = undefined;
    const text = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 13\r\n\r\nHello, World!";
    @memcpy(buffer[0..text.len], text);

    const resp = try transport.parseHttpResponse(&buffer, text.len);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqual(@as(usize, 13), resp.content_length.?);
    try std.testing.expect(!resp.chunked);
    try std.testing.expectEqualStrings("Hello, World!", resp.body());
}

test "parseHttpResponse — 404" {
    var buffer: [256]u8 = undefined;
    const text = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found";
    @memcpy(buffer[0..text.len], text);

    const resp = try transport.parseHttpResponse(&buffer, text.len);
    try std.testing.expectEqual(@as(u16, 404), resp.status_code);
}

test "parseHttpResponse — chunked" {
    var buffer: [256]u8 = undefined;
    const text = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n";
    @memcpy(buffer[0..text.len], text);

    const resp = try transport.parseHttpResponse(&buffer, text.len);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expect(resp.chunked);
}

test "parseHttpResponse — too short" {
    var buffer: [8]u8 = undefined;
    try std.testing.expectError(error.InvalidResponse, transport.parseHttpResponse(&buffer, 5));
}

test "RoundTripResponse.isSuccess" {
    var buffer: [256]u8 = undefined;

    const ok_text = "HTTP/1.1 200 OK\r\n\r\n";
    @memcpy(buffer[0..ok_text.len], ok_text);
    const ok_resp = try transport.parseHttpResponse(&buffer, ok_text.len);
    try std.testing.expect(ok_resp.isSuccess());

    const err_text = "HTTP/1.1 500 Internal Server Error\r\n\r\n";
    @memcpy(buffer[0..err_text.len], err_text);
    const err_resp = try transport.parseHttpResponse(&buffer, err_text.len);
    try std.testing.expect(!err_resp.isSuccess());
}

test "RoundTripResponse.headerValue" {
    var buffer: [256]u8 = undefined;
    const text = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Custom: hello\r\n\r\n{}";
    @memcpy(buffer[0..text.len], text);

    const resp = try transport.parseHttpResponse(&buffer, text.len);
    try std.testing.expectEqualStrings("application/json", resp.headerValue("content-type").?);
    try std.testing.expectEqualStrings("hello", resp.headerValue("X-Custom").?);
    try std.testing.expect(resp.headerValue("X-Missing") == null);
}

test "isResponseComplete" {
    const complete = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    try std.testing.expect(transport.isResponseComplete(complete));

    const partial = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nhello";
    try std.testing.expect(!transport.isResponseComplete(partial));

    const no_headers = "HTTP/1.1 200 OK\r\n";
    try std.testing.expect(!transport.isResponseComplete(no_headers));
}

test "Transport comptime validation" {
    const T = transport.Transport(Std, void);
    _ = transport.RoundTripper(T);
}

test "HTTP GET httpbin.org/get" {
    const T = transport.Transport(Std, void);
    var t = T{ .allocator = std.testing.allocator, .dns_server = dns_mod.Servers.alidns };

    var buf: [8192]u8 = undefined;
    const resp = t.roundTrip(.{
        .host = "httpbin.org",
        .path = "/get",
        .timeout_ms = 10000,
    }, &buf) catch |err| switch (err) {
        error.ConnectionFailed, error.DnsResolveFailed, error.Timeout, error.ReceiveFailed => return,
        else => return err,
    };
    try std.testing.expect(resp.status_code == 200 or resp.status_code == 301 or resp.status_code == 302);
}

test "HTTP GET to IP address (no DNS)" {
    const T = transport.Transport(Std, void);
    var t = T{ .allocator = std.testing.allocator };

    var buf: [4096]u8 = undefined;
    const resp = t.roundTrip(.{
        .host = "223.5.5.5",
        .port = 80,
        .path = "/",
        .timeout_ms = 5000,
    }, &buf) catch |err| switch (err) {
        error.ConnectionFailed, error.Timeout, error.ReceiveFailed => return,
        else => return err,
    };
    try std.testing.expect(resp.status_code >= 200 and resp.status_code < 600);
}

test "HTTP GET with DNS resolution" {
    const T = transport.Transport(Std, void);
    var t = T{ .allocator = std.testing.allocator, .dns_server = dns_mod.Servers.alidns };

    var buf: [8192]u8 = undefined;
    const resp = t.roundTrip(.{
        .host = "www.baidu.com",
        .path = "/",
        .timeout_ms = 10000,
    }, &buf) catch |err| switch (err) {
        error.ConnectionFailed, error.DnsResolveFailed, error.Timeout, error.ReceiveFailed => return,
        else => return err,
    };
    try std.testing.expect(resp.status_code >= 200 and resp.status_code < 600);
    try std.testing.expect(resp.body().len > 0);
}

test "HTTP POST with body" {
    const T = transport.Transport(Std, void);
    var t = T{ .allocator = std.testing.allocator, .dns_server = dns_mod.Servers.alidns };

    var buf: [8192]u8 = undefined;
    const resp = t.roundTrip(.{
        .method = .POST,
        .host = "httpbin.org",
        .path = "/post",
        .body = "{\"test\": true}",
        .content_type = "application/json",
        .timeout_ms = 10000,
    }, &buf) catch |err| switch (err) {
        error.ConnectionFailed, error.DnsResolveFailed, error.Timeout, error.ReceiveFailed => return,
        else => return err,
    };
    try std.testing.expect(resp.status_code == 200 or resp.status_code == 301 or resp.status_code == 302);
}

test "HTTP nonexistent host returns DnsResolveFailed" {
    const T = transport.Transport(Std, void);
    var t = T{ .allocator = std.testing.allocator, .dns_server = dns_mod.Servers.alidns };

    var buf: [4096]u8 = undefined;
    const result = t.roundTrip(.{
        .host = "this.host.does.not.exist.invalid",
        .path = "/",
        .timeout_ms = 5000,
    }, &buf);
    try std.testing.expectError(error.DnsResolveFailed, result);
}

test "HTTP HTTPS with TLS" {
    const T = transport.Transport(Std, void);
    var t = T{ .allocator = std.testing.allocator, .dns_server = dns_mod.Servers.alidns };

    var buf: [4096]u8 = undefined;
    const result = t.roundTrip(.{
        .scheme = .https,
        .host = "example.com",
        .port = 443,
        .path = "/",
        .timeout_ms = 5000,
    }, &buf);
    if (result) |resp| {
        try std.testing.expect(resp.status_code >= 200 and resp.status_code < 600);
    } else |err| {
        try std.testing.expect(err == error.DnsResolveFailed or err == error.TlsHandshakeFailed or err == error.TlsError or err == error.Timeout or err == error.ConnectionFailed);
    }
}

test "Transport with DomainResolver intercepts" {
    const FakeResolver = struct {
        pub fn resolve(_: *const @This(), host: []const u8) ?[4]u8 {
            if (std.mem.eql(u8, host, "mydevice.local")) return .{ 127, 0, 0, 1 };
            return null;
        }
    };
    const T = transport.Transport(Std, FakeResolver);
    const custom = FakeResolver{};
    var t = T{
        .allocator = std.testing.allocator,
        .custom_resolver = &custom,
    };

    var buf: [4096]u8 = undefined;
    const result = t.roundTrip(.{
        .host = "mydevice.local",
        .port = 1,
        .path = "/",
        .timeout_ms = 1000,
    }, &buf);
    if (result) |_| {} else |err| {
        try std.testing.expect(err == error.ConnectionFailed);
    }
}

test "concurrent HTTP GETs from multiple threads" {
    const T = transport.Transport(Std, void);

    const Worker = struct {
        fn run(host: []const u8) void {
            var t = T{ .allocator = std.testing.allocator, .dns_server = dns_mod.Servers.alidns };
            var buf: [8192]u8 = undefined;
            const resp = t.roundTrip(.{
                .host = host,
                .path = "/",
                .timeout_ms = 10000,
            }, &buf) catch return;
            std.debug.assert(resp.status_code >= 100 and resp.status_code < 600);
        }
    };

    var threads: [3]std.Thread = undefined;
    const hosts = [_][]const u8{ "www.baidu.com", "httpbin.org", "www.example.com" };
    for (hosts, 0..) |host, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{host});
    }
    for (&threads) |*t| t.join();
}

test "concurrent HTTP requests — same host" {
    const T = transport.Transport(Std, void);

    const Worker = struct {
        fn run() void {
            var t = T{ .allocator = std.testing.allocator, .dns_server = dns_mod.Servers.alidns };
            var buf: [8192]u8 = undefined;
            const resp = t.roundTrip(.{
                .host = "www.baidu.com",
                .path = "/",
                .timeout_ms = 10000,
            }, &buf) catch return;
            std.debug.assert(resp.status_code >= 100 and resp.status_code < 600);
        }
    };

    var threads: [4]std.Thread = undefined;
    for (0..4) |i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{});
    }
    for (&threads) |*t| t.join();
}
