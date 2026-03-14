//! HTTP Transport layer — Go-style RoundTripper pattern.
//!
//! `RoundTripper` is a contract: given an HTTP request, produce an HTTP response.
//!
//! `Transport` is the default implementation that handles:
//!   - URL parsing
//!   - DNS resolution
//!   - TCP connection establishment
//!   - TLS handshake (for HTTPS)
//!   - HTTP request/response over the wire
//!
//! The `Client` type (in client.zig) depends only on the `RoundTripper` contract,
//! not on `Transport` directly — enabling mock transports for testing.

const std = @import("std");
const runtime = struct {
    pub const socket = @import("../../../runtime/socket.zig");
    pub const std = @import("../../../runtime/std.zig");
};
const conn_mod = @import("../conn.zig");
const tls_mod = struct {
    pub fn Client(comptime Conn: type, comptime Crypto: type, comptime Mutex: type) type {
        return @import("../tls/client.zig").Client(Conn, Crypto, Mutex);
    }
};
const dns_mod = @import("../dns/dns.zig");
const url_mod = @import("../url/url.zig");
const request_mod = @import("request.zig");

pub const Method = request_mod.Method;

pub const Scheme = enum {
    http,
    https,
};

/// HTTP request descriptor for RoundTripper.
pub const RoundTripRequest = struct {
    method: Method = .GET,
    scheme: Scheme = .http,
    host: []const u8,
    port: u16 = 80,
    path: []const u8 = "/",
    body: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    user_agent: []const u8 = "zig-http/0.1",
    timeout_ms: u32 = 30000,
    extra_headers: ?[]const u8 = null,
};

/// HTTP response from RoundTripper.
pub const RoundTripResponse = struct {
    status_code: u16,
    content_length: ?usize,
    chunked: bool,
    headers_end: usize,
    body_start: usize,
    buffer: []u8,
    buffer_len: usize,

    pub fn body(self: *const RoundTripResponse) []const u8 {
        if (self.body_start >= self.buffer_len) return &[_]u8{};
        return self.buffer[self.body_start..self.buffer_len];
    }

    pub fn isSuccess(self: *const RoundTripResponse) bool {
        return self.status_code >= 200 and self.status_code < 300;
    }

    pub fn headerValue(self: *const RoundTripResponse, name: []const u8) ?[]const u8 {
        const headers = self.buffer[0..self.headers_end];
        var i: usize = 0;
        while (i < headers.len) {
            const line_end = std.mem.indexOfPos(u8, headers, i, "\r\n") orelse break;
            const line = headers[i..line_end];
            if (line.len == 0) break;

            const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
                i = line_end + 2;
                continue;
            };
            const hdr_name = std.mem.trim(u8, line[0..colon], " \t");
            if (std.ascii.eqlIgnoreCase(hdr_name, name)) {
                return std.mem.trim(u8, line[colon + 1 ..], " \t");
            }
            i = line_end + 2;
        }
        return null;
    }
};

pub const TransportError = error{
    InvalidUrl,
    DnsResolveFailed,
    ConnectionFailed,
    SendFailed,
    ReceiveFailed,
    Timeout,
    InvalidResponse,
    TlsError,
    TlsHandshakeFailed,
    TlsNotSupported,
    BufferTooSmall,
};

/// Validate that `Impl` satisfies the RoundTripper contract.
///
/// Required method:
///   `fn roundTrip(*Impl, RoundTripRequest, []u8) TransportError!RoundTripResponse`
pub fn RoundTripper(comptime Impl: type) type {
    comptime {
        _ = @as(
            *const fn (*Impl, RoundTripRequest, []u8) TransportError!RoundTripResponse,
            &Impl.roundTrip,
        );
    }
    return Impl;
}

/// Default HTTP Transport — handles DNS, TCP, TLS, and HTTP over the wire.
///
/// Type parameters:
///   - `Socket`: must satisfy `runtime.socket.from` contract
///   - `Crypto`: crypto primitives for TLS (pass `void` for HTTP-only)
///   - `Mutex`: mutex type for TLS thread safety (pass `void` for HTTP-only)
///   - `DomainResolver`: custom DNS resolver (pass `void` to disable)
pub fn Transport(
    comptime Socket: type,
    comptime Crypto: type,
    comptime Mutex: type,
    comptime DomainResolver: type,
) type {
    comptime _ = runtime.socket.from(Socket);

    const has_tls = Crypto != void and Mutex != void;
    const has_custom_resolver = DomainResolver != void;

    const SConn = conn_mod.SocketConn(Socket);
    const TlsClient = if (has_tls) tls_mod.Client(SConn, Crypto, Mutex) else void;
    const DnsResolver = dns_mod.Resolver(Socket, DomainResolver);

    const CaStore = if (Crypto != void and @hasDecl(Crypto, "x509") and @hasDecl(Crypto.x509, "CaStore"))
        Crypto.x509.CaStore
    else
        void;

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        dns_server: [4]u8 = dns_mod.Servers.alidns,
        dns_timeout_ms: u32 = 5000,
        ca_store: if (CaStore != void) ?CaStore else void = if (CaStore != void) null else {},
        user_agent: []const u8 = "zig-http/0.1",
        custom_resolver: if (has_custom_resolver) ?*const DomainResolver else void =
            if (has_custom_resolver) null else {},

        pub const CaStoreType = CaStore;

        pub fn roundTrip(self: *Self, req: RoundTripRequest, buffer: []u8) TransportError!RoundTripResponse {
            const addr = self.resolveHost(req.host) orelse return error.DnsResolveFailed;

            var socket = Socket.tcp() catch return error.ConnectionFailed;

            socket.setRecvTimeout(req.timeout_ms);
            socket.setSendTimeout(req.timeout_ms);
            socket.setTcpNoDelay(true);

            socket.connect(addr, req.port) catch {
                socket.close();
                return error.ConnectionFailed;
            };

            if (req.scheme == .https) {
                if (!has_tls) return error.TlsNotSupported;
                return self.roundTripHttps(&socket, req, buffer);
            }

            return roundTripPlain(&socket, req, buffer);
        }

        fn resolveHost(self: *const Self, host: []const u8) ?[4]u8 {
            if (runtime.socket.parseIpv4(host)) |addr| return addr;

            var resolver = DnsResolver{
                .server = self.dns_server,
                .protocol = .udp,
                .timeout_ms = self.dns_timeout_ms,
            };
            if (has_custom_resolver) {
                resolver.custom_resolver = self.custom_resolver;
            }

            return resolver.resolve(host) catch null;
        }

        fn roundTripPlain(socket: *Socket, req: RoundTripRequest, buffer: []u8) TransportError!RoundTripResponse {
            defer socket.close();

            try sendHttpRequest(socket, req);
            return recvHttpResponse(socket, buffer);
        }

        fn roundTripHttps(self: *Self, socket: *Socket, req: RoundTripRequest, buffer: []u8) TransportError!RoundTripResponse {
            defer socket.close();

            var socket_conn = SConn.init(socket);

            const skip_verify = if (CaStore != void) self.ca_store == null else true;
            const ca_store_val = if (CaStore != void) self.ca_store else {};

            var tls_client = TlsClient.init(&socket_conn, .{
                .allocator = self.allocator,
                .hostname = req.host,
                .skip_verify = skip_verify,
                .ca_store = ca_store_val,
                .timeout_ms = req.timeout_ms,
            }) catch return error.TlsError;
            defer tls_client.deinit();

            tls_client.connect() catch return error.TlsHandshakeFailed;

            var req_buf: [2048]u8 = undefined;
            const req_len = buildHttpRequest(&req_buf, req) catch return error.BufferTooSmall;

            _ = tls_client.send(req_buf[0..req_len]) catch return error.SendFailed;

            var total_received: usize = 0;
            while (total_received < buffer.len) {
                const n = tls_client.recv(buffer[total_received..]) catch {
                    if (total_received > 0) break;
                    return error.ReceiveFailed;
                };
                if (n == 0) break;
                total_received += n;

                if (isResponseComplete(buffer[0..total_received])) break;
            }

            return parseHttpResponse(buffer, total_received);
        }

        fn sendHttpRequest(socket: *Socket, req: RoundTripRequest) TransportError!void {
            var req_buf: [2048]u8 = undefined;
            const req_len = buildHttpRequest(&req_buf, req) catch return error.BufferTooSmall;

            _ = socket.send(req_buf[0..req_len]) catch return error.SendFailed;
        }

        fn recvHttpResponse(socket: *Socket, buffer: []u8) TransportError!RoundTripResponse {
            var total_received: usize = 0;
            while (total_received < buffer.len) {
                const n = socket.recv(buffer[total_received..]) catch |err| {
                    if ((err == error.Timeout or err == error.Closed) and total_received > 0) break;
                    return error.ReceiveFailed;
                };
                if (n == 0) break;
                total_received += n;

                if (isResponseComplete(buffer[0..total_received])) break;
            }

            return parseHttpResponse(buffer, total_received);
        }

        comptime {
            _ = RoundTripper(Self);
        }
    };
}

// =========================================================================
// Shared HTTP helpers
// =========================================================================

pub fn buildHttpRequest(buf: []u8, req: RoundTripRequest) !usize {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    try w.print("{s} {s} HTTP/1.1\r\n", .{ req.method.toString(), req.path });
    try w.print("Host: {s}\r\n", .{req.host});
    try w.print("User-Agent: {s}\r\n", .{req.user_agent});
    try w.writeAll("Connection: close\r\n");

    if (req.body) |data| {
        try w.print("Content-Length: {d}\r\n", .{data.len});
    }

    if (req.content_type) |ct| {
        try w.print("Content-Type: {s}\r\n", .{ct});
    }

    if (req.extra_headers) |hdrs| {
        try w.writeAll(hdrs);
    }

    try w.writeAll("\r\n");

    if (req.body) |data| {
        try w.writeAll(data);
    }

    return fbs.pos;
}

pub fn findHeaderEnd(data: []const u8) ?usize {
    if (data.len < 4) return null;
    for (0..data.len - 3) |i| {
        if (std.mem.eql(u8, data[i .. i + 4], "\r\n\r\n")) {
            return i + 4;
        }
    }
    return null;
}

pub fn parseContentLength(headers: []const u8) ?usize {
    var i: usize = 0;
    while (i < headers.len) {
        const line_end = std.mem.indexOfPos(u8, headers, i, "\r\n") orelse break;
        const line = headers[i..line_end];

        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line["content-length:".len..], " ");
            return std.fmt.parseInt(usize, value, 10) catch null;
        }

        i = line_end + 2;
    }
    return null;
}

pub fn isResponseComplete(data: []const u8) bool {
    const headers_end = findHeaderEnd(data) orelse return false;
    const content_len = parseContentLength(data[0..headers_end]) orelse return false;
    return data.len >= headers_end + content_len;
}

pub fn parseHttpResponse(buffer: []u8, len: usize) TransportError!RoundTripResponse {
    if (len < 12) return error.InvalidResponse;

    if (!std.mem.startsWith(u8, buffer[0..len], "HTTP/1.")) {
        return error.InvalidResponse;
    }

    const status_start = 9;
    if (len < status_start + 3) return error.InvalidResponse;

    const status_code = std.fmt.parseInt(u16, buffer[status_start .. status_start + 3], 10) catch {
        return error.InvalidResponse;
    };

    const headers_end = findHeaderEnd(buffer[0..len]) orelse return error.InvalidResponse;

    var content_length: ?usize = null;
    var chunked = false;

    var i: usize = 0;
    while (i < headers_end) {
        const line_end = std.mem.indexOfPos(u8, buffer[0..headers_end], i, "\r\n") orelse break;
        const line = buffer[i..line_end];

        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line["content-length:".len..], " ");
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
        } else if (std.ascii.startsWithIgnoreCase(line, "transfer-encoding:")) {
            const value = std.mem.trim(u8, line["transfer-encoding:".len..], " ");
            chunked = std.ascii.indexOfIgnoreCase(value, "chunked") != null;
        }

        i = line_end + 2;
    }

    return .{
        .status_code = status_code,
        .content_length = content_length,
        .chunked = chunked,
        .headers_end = headers_end,
        .body_start = headers_end,
        .buffer = buffer,
        .buffer_len = len,
    };
}

/// Parse a URL string into a RoundTripRequest (method defaults to GET).
pub fn requestFromUrl(url_str: []const u8) TransportError!RoundTripRequest {
    const parsed = url_mod.parse(url_str) catch return error.InvalidUrl;

    const scheme_str = parsed.scheme orelse "";
    const scheme: Scheme = if (std.mem.eql(u8, scheme_str, "https"))
        .https
    else if (std.mem.eql(u8, scheme_str, "http") or scheme_str.len == 0)
        .http
    else
        return error.InvalidUrl;

    const host = parsed.host orelse return error.InvalidUrl;
    if (host.len == 0) return error.InvalidUrl;

    const default_port: u16 = if (scheme == .https) 443 else 80;
    const port = parsed.port orelse default_port;
    const path = if (parsed.path.len > 0) parsed.path else "/";

    return .{
        .scheme = scheme,
        .host = host,
        .port = port,
        .path = path,
    };
}

// =========================================================================
// Tests
// =========================================================================

// =========================================================================
// Real network tests — Transport(Socket, void, void, void) for HTTP-only
// =========================================================================
