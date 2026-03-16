const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const module = embed.pkg.net.http.transport;
const Method = module.Method;
const Scheme = module.Scheme;
const RoundTripRequest = module.RoundTripRequest;
const RoundTripResponse = module.RoundTripResponse;
const TransportError = module.TransportError;
const RoundTripper = module.RoundTripper;
const Transport = module.Transport;
const requestFromUrl = module.requestFromUrl;
const runtime = embed.runtime;
const conn_mod = embed.pkg.net.conn;
const tls_mod = embed.pkg.net.tls;
const dns_mod = embed.pkg.net.dns;
const url_mod = embed.pkg.net.url;
const request_mod = embed.pkg.net.http.request;
const buildHttpRequest = module.buildHttpRequest;
const findHeaderEnd = module.findHeaderEnd;
const parseContentLength = module.parseContentLength;
const isResponseComplete = module.isResponseComplete;
const parseHttpResponse = module.parseHttpResponse;

test "RoundTripper contract with mock" {
    const MockTransport = struct {
        const Self = @This();
        pub fn roundTrip(_: *Self, _: RoundTripRequest, buffer: []u8) TransportError!RoundTripResponse {
            const resp_text = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK";
            @memcpy(buffer[0..resp_text.len], resp_text);
            return parseHttpResponse(buffer, resp_text.len);
        }
    };
    _ = RoundTripper(MockTransport);

    var mock = MockTransport{};
    var buf: [256]u8 = undefined;
    const resp = try mock.roundTrip(.{ .host = "example.com" }, &buf);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqualStrings("OK", resp.body());
}

test "requestFromUrl — HTTP" {
    const req = try requestFromUrl("http://example.com/api/v1?key=val");
    try std.testing.expectEqual(Scheme.http, req.scheme);
    try std.testing.expectEqualStrings("example.com", req.host);
    try std.testing.expectEqual(@as(u16, 80), req.port);
    try std.testing.expectEqualStrings("/api/v1", req.path);
}

test "requestFromUrl — HTTPS with port" {
    const req = try requestFromUrl("https://api.example.com:8443/data");
    try std.testing.expectEqual(Scheme.https, req.scheme);
    try std.testing.expectEqualStrings("api.example.com", req.host);
    try std.testing.expectEqual(@as(u16, 8443), req.port);
    try std.testing.expectEqualStrings("/data", req.path);
}

test "requestFromUrl — HTTPS default port" {
    const req = try requestFromUrl("https://secure.example.com/");
    try std.testing.expectEqual(Scheme.https, req.scheme);
    try std.testing.expectEqual(@as(u16, 443), req.port);
}

test "requestFromUrl — no path" {
    const req = try requestFromUrl("http://example.com");
    try std.testing.expectEqualStrings("/", req.path);
}

test "requestFromUrl — empty host" {
    try std.testing.expectError(error.InvalidUrl, requestFromUrl("http:///path"));
}

test "buildHttpRequest — GET" {
    var buf: [2048]u8 = undefined;
    const len = try buildHttpRequest(&buf, .{
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
    const len = try buildHttpRequest(&buf, .{
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
    const end = findHeaderEnd(data).?;
    try std.testing.expectEqual(@as(usize, 44), end);
    try std.testing.expectEqualStrings("Body", data[end..]);
}

test "findHeaderEnd — incomplete" {
    try std.testing.expect(findHeaderEnd("HTTP/1.1 200 OK\r\n") == null);
}

test "parseContentLength" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Length: 1234\r\n\r\n";
    try std.testing.expectEqual(@as(usize, 1234), parseContentLength(headers).?);
}

test "parseContentLength — absent" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n";
    try std.testing.expect(parseContentLength(headers) == null);
}

test "parseHttpResponse — 200 OK" {
    var buffer: [256]u8 = undefined;
    const text = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 13\r\n\r\nHello, World!";
    @memcpy(buffer[0..text.len], text);

    const resp = try parseHttpResponse(&buffer, text.len);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqual(@as(usize, 13), resp.content_length.?);
    try std.testing.expect(!resp.chunked);
    try std.testing.expectEqualStrings("Hello, World!", resp.body());
}

test "parseHttpResponse — 404" {
    var buffer: [256]u8 = undefined;
    const text = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found";
    @memcpy(buffer[0..text.len], text);

    const resp = try parseHttpResponse(&buffer, text.len);
    try std.testing.expectEqual(@as(u16, 404), resp.status_code);
}

test "parseHttpResponse — chunked" {
    var buffer: [256]u8 = undefined;
    const text = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n";
    @memcpy(buffer[0..text.len], text);

    const resp = try parseHttpResponse(&buffer, text.len);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expect(resp.chunked);
}

test "parseHttpResponse — too short" {
    var buffer: [8]u8 = undefined;
    try std.testing.expectError(error.InvalidResponse, parseHttpResponse(&buffer, 5));
}

test "RoundTripResponse.isSuccess" {
    var buffer: [256]u8 = undefined;

    const ok_text = "HTTP/1.1 200 OK\r\n\r\n";
    @memcpy(buffer[0..ok_text.len], ok_text);
    const ok_resp = try parseHttpResponse(&buffer, ok_text.len);
    try std.testing.expect(ok_resp.isSuccess());

    const err_text = "HTTP/1.1 500 Internal Server Error\r\n\r\n";
    @memcpy(buffer[0..err_text.len], err_text);
    const err_resp = try parseHttpResponse(&buffer, err_text.len);
    try std.testing.expect(!err_resp.isSuccess());
}

test "RoundTripResponse.headerValue" {
    var buffer: [256]u8 = undefined;
    const text = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Custom: hello\r\n\r\n{}";
    @memcpy(buffer[0..text.len], text);

    const resp = try parseHttpResponse(&buffer, text.len);
    try std.testing.expectEqualStrings("application/json", resp.headerValue("content-type").?);
    try std.testing.expectEqualStrings("hello", resp.headerValue("X-Custom").?);
    try std.testing.expect(resp.headerValue("X-Missing") == null);
}

test "isResponseComplete" {
    const complete = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    try std.testing.expect(isResponseComplete(complete));

    const partial = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nhello";
    try std.testing.expect(!isResponseComplete(partial));

    const no_headers = "HTTP/1.1 200 OK\r\n";
    try std.testing.expect(!isResponseComplete(no_headers));
}

test "Transport comptime validation" {
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void, void);
    _ = RoundTripper(T);
}

test "HTTP GET httpbin.org/get" {
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void, void);
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
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void, void);
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
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void, void);
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
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void, void);
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
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void, void);
    var t = T{ .allocator = std.testing.allocator, .dns_server = dns_mod.Servers.alidns };

    var buf: [4096]u8 = undefined;
    const result = t.roundTrip(.{
        .host = "this.host.does.not.exist.invalid",
        .path = "/",
        .timeout_ms = 5000,
    }, &buf);
    try std.testing.expectError(error.DnsResolveFailed, result);
}

test "HTTP HTTPS without TLS returns TlsNotSupported" {
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void, void);
    var t = T{ .allocator = std.testing.allocator, .dns_server = dns_mod.Servers.alidns };

    var buf: [4096]u8 = undefined;
    const result = t.roundTrip(.{
        .scheme = .https,
        .host = "example.com",
        .port = 443,
        .path = "/",
        .timeout_ms = 5000,
    }, &buf);
    if (result) |_| {
        return error.ExpectedError;
    } else |err| {
        try std.testing.expect(err == error.TlsNotSupported or err == error.DnsResolveFailed);
    }
}

test "Transport with DomainResolver intercepts" {
    const Socket = runtime.std.Socket;
    const FakeResolver = struct {
        pub fn resolve(_: *const @This(), host: []const u8) ?[4]u8 {
            if (std.mem.eql(u8, host, "mydevice.local")) return .{ 127, 0, 0, 1 };
            return null;
        }
    };
    const T = Transport(Socket, void, void, void, FakeResolver);
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
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void, void);

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
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void, void);

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
