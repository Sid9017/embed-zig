//! HTTP Client — high-level API over a RoundTripper.
//!
//! The Client depends only on the `RoundTripper` contract, not on any
//! specific transport implementation. This enables:
//!   - Real HTTP/HTTPS via `Transport(Socket, Crypto, Rng, Mutex, ...)`
//!   - Mock transports for unit testing
//!
//! Usage:
//!
//!   // Full-featured (HTTP + HTTPS + DNS)
//!   const T = http.Transport(Socket, Crypto, Rng, Mutex, void);
//!   var transport = T{ .allocator = allocator };
//!   var client = http.Client(T).init(&transport, allocator);
//!   var buf: [8192]u8 = undefined;
//!   const resp = try client.get("https://example.com/api", &buf);
//!
//!   // HTTP-only (no TLS)
//!   const T = http.Transport(Socket, void, void, void, void);
//!   var transport = T{ .allocator = allocator };
//!   var client = http.Client(T).init(&transport, allocator);

const std = @import("std");
const transport_mod = @import("transport.zig");

const RoundTripRequest = transport_mod.RoundTripRequest;
const RoundTripResponse = transport_mod.RoundTripResponse;
const TransportError = transport_mod.TransportError;
pub const Scheme = transport_mod.Scheme;
pub const Method = transport_mod.Method;

pub fn Client(comptime RT: type) type {
    comptime _ = transport_mod.RoundTripper(RT);

    return struct {
        const Self = @This();

        transport: *RT,
        user_agent: []const u8 = "zig-http/0.1",
        timeout_ms: u32 = 30000,

        pub fn init(rt: *RT) Self {
            return .{ .transport = rt };
        }

        pub fn get(self: *Self, url: []const u8, buffer: []u8) TransportError!RoundTripResponse {
            return self.request(.GET, url, null, null, buffer);
        }

        pub fn post(self: *Self, url: []const u8, body: ?[]const u8, buffer: []u8) TransportError!RoundTripResponse {
            return self.request(.POST, url, body, null, buffer);
        }

        pub fn postJson(self: *Self, url: []const u8, body: []const u8, buffer: []u8) TransportError!RoundTripResponse {
            return self.request(.POST, url, body, "application/json", buffer);
        }

        pub fn put(self: *Self, url: []const u8, body: ?[]const u8, buffer: []u8) TransportError!RoundTripResponse {
            return self.request(.PUT, url, body, null, buffer);
        }

        pub fn delete(self: *Self, url: []const u8, buffer: []u8) TransportError!RoundTripResponse {
            return self.request(.DELETE, url, null, null, buffer);
        }

        pub fn request(
            self: *Self,
            method: Method,
            url: []const u8,
            body: ?[]const u8,
            content_type: ?[]const u8,
            buffer: []u8,
        ) TransportError!RoundTripResponse {
            var req = transport_mod.requestFromUrl(url) catch return error.InvalidUrl;
            req.method = method;
            req.body = body;
            req.content_type = content_type;
            req.user_agent = self.user_agent;
            req.timeout_ms = self.timeout_ms;
            return self.transport.roundTrip(req, buffer);
        }

        pub fn requestWithHeaders(
            self: *Self,
            method: Method,
            url: []const u8,
            body: ?[]const u8,
            content_type: ?[]const u8,
            extra_headers: []const u8,
            buffer: []u8,
        ) TransportError!RoundTripResponse {
            var req = transport_mod.requestFromUrl(url) catch return error.InvalidUrl;
            req.method = method;
            req.body = body;
            req.content_type = content_type;
            req.extra_headers = extra_headers;
            req.user_agent = self.user_agent;
            req.timeout_ms = self.timeout_ms;
            return self.transport.roundTrip(req, buffer);
        }
    };
}

// =========================================================================
// Tests
// =========================================================================

pub const MockTransport = struct {
    call_count: usize = 0,
    last_method: ?Method = null,
    last_host: ?[]const u8 = null,
    last_path: ?[]const u8 = null,
    last_scheme: ?Scheme = null,
    response_text: []const u8 = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK",

    pub fn roundTrip(self: *MockTransport, req: RoundTripRequest, buffer: []u8) TransportError!RoundTripResponse {
        self.call_count += 1;
        self.last_method = req.method;
        self.last_host = req.host;
        self.last_path = req.path;
        self.last_scheme = req.scheme;

        const text = self.response_text;
        if (text.len > buffer.len) return error.BufferTooSmall;
        @memcpy(buffer[0..text.len], text);

        if (text.len < 12) return error.InvalidResponse;
        if (!std.mem.startsWith(u8, text, "HTTP/1.")) return error.InvalidResponse;

        const status_code = std.fmt.parseInt(u16, text[9..12], 10) catch return error.InvalidResponse;

        var headers_end: usize = 0;
        if (text.len >= 4) {
            for (0..text.len - 3) |i| {
                if (std.mem.eql(u8, text[i .. i + 4], "\r\n\r\n")) {
                    headers_end = i + 4;
                    break;
                }
            }
        }
        if (headers_end == 0) return error.InvalidResponse;

        return .{
            .status_code = status_code,
            .content_length = text.len - headers_end,
            .chunked = false,
            .headers_end = headers_end,
            .body_start = headers_end,
            .buffer = buffer,
            .buffer_len = text.len,
        };
    }
};

pub fn initMockClient(mock: *MockTransport) Client(MockTransport) {
    return .{ .transport = mock };
}
