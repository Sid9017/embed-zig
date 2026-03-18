//! HTTP Client — high-level API over a RoundTripper.
//!
//! The Client depends only on the `RoundTripper` contract, not on any
//! specific transport implementation. This enables:
//!   - Real HTTP/HTTPS via `Transport(Socket, Runtime, ...)`
//!   - Mock transports for unit testing
//!
//! Usage:
//!
//!   // Full-featured (HTTP + HTTPS + DNS)
//!   const T = http.Transport(Socket, Runtime, void);
//!   var transport = T{ .allocator = allocator };
//!   var client = http.Client(T).init(&transport, allocator);
//!   var buf: [8192]u8 = undefined;
//!   const resp = try client.get("https://example.com/api", &buf);
//!
//!   // HTTP-only (no TLS)
//!   const T = http.Transport(Socket, void, void);
//!   var transport = T{ .allocator = allocator };
//!   var client = http.Client(T).init(&transport, allocator);

const std = @import("std");
const request_mod = @import("request.zig");
const transport_mod = @import("transport.zig");

const RoundTripRequest = transport_mod.RoundTripRequest;
const RoundTripResponse = transport_mod.RoundTripResponse;
const TransportError = transport_mod.TransportError;
const Scheme = transport_mod.Scheme;
const Method = request_mod.Method;

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
