//! Cross-Platform DNS Resolver
//!
//! Supports UDP, TCP, and DNS over HTTPS (DoH, RFC 8484).
//!
//! Example:
//!   const dns = @import("dns");
//!
//!   // Create resolver with platform socket (UDP/TCP only, no custom resolution)
//!   const R = dns.Resolver(Socket, void);
//!   var resolver = R{ .server = .{ 223, 5, 5, 5 }, .protocol = .udp };
//!
//!   // Create resolver with TLS support (UDP/TCP/HTTPS)
//!   const R2 = dns.ResolverWithTls(Socket, Crypto, Mutex, void);
//!   var resolver_tls = R2{
//!       .server = .{ 223, 5, 5, 5 },
//!       .protocol = .https,
//!       .doh_host = "dns.alidns.com",
//!       .allocator = allocator,
//!   };
//!
//!   const ip = try resolver.resolve("www.google.com");

const std = @import("std");
const runtime = struct {
    pub const socket = @import("../../../runtime/socket.zig");
    pub const sync = struct {
        pub const mutex = @import("../../../runtime/sync/mutex.zig");
    };
    pub const std = @import("../../../runtime/std.zig");
};
const conn_mod = @import("../conn.zig");
const tls = struct {
    pub fn Client(comptime Conn: type, comptime Crypto: type, comptime Rng: type, comptime Mutex: type) type {
        return @import("../tls/client.zig").Client(Conn, Crypto, Rng, Mutex);
    }
};

pub const Ipv4Address = [4]u8;

/// Well-known public DNS servers
pub const Servers = struct {
    /// AliDNS (China, anycast)
    pub const alidns: Ipv4Address = .{ 223, 5, 5, 5 };
    pub const alidns2: Ipv4Address = .{ 223, 6, 6, 6 };

    /// DNSPod / Tencent (China)
    pub const dnspod: Ipv4Address = .{ 119, 29, 29, 29 };

    /// 114 DNS (China)
    pub const dns114: Ipv4Address = .{ 114, 114, 114, 114 };
    pub const dns114_2: Ipv4Address = .{ 114, 114, 115, 115 };

    /// Google Public DNS (Global)
    pub const google: Ipv4Address = .{ 8, 8, 8, 8 };
    pub const google2: Ipv4Address = .{ 8, 8, 4, 4 };

    /// Cloudflare DNS (Global, anycast)
    pub const cloudflare: Ipv4Address = .{ 1, 1, 1, 1 };
    pub const cloudflare2: Ipv4Address = .{ 1, 0, 0, 1 };

    /// Quad9 (Global, security-focused)
    pub const quad9: Ipv4Address = .{ 9, 9, 9, 9 };

    /// OpenDNS / Cisco (Global)
    pub const opendns: Ipv4Address = .{ 208, 67, 222, 222 };
    pub const opendns2: Ipv4Address = .{ 208, 67, 220, 220 };
};

/// DoH (DNS over HTTPS) server hostnames, paired with Servers addresses
pub const DohHosts = struct {
    pub const alidns: []const u8 = "dns.alidns.com";
    pub const dnspod: []const u8 = "doh.pub";
    pub const google: []const u8 = "dns.google";
    pub const cloudflare: []const u8 = "cloudflare-dns.com";
    pub const quad9: []const u8 = "dns.quad9.net";
};

/// Preset server lists for different network environments
pub const ServerLists = struct {
    /// China optimized
    pub const china = [_]Ipv4Address{
        Servers.alidns,
        Servers.dnspod,
        Servers.dns114,
    };

    /// Global / overseas
    pub const global = [_]Ipv4Address{
        Servers.cloudflare,
        Servers.google,
        Servers.quad9,
    };

    /// Mixed (works everywhere)
    pub const mixed = [_]Ipv4Address{
        Servers.alidns,
        Servers.cloudflare,
        Servers.google,
    };
};

pub const DnsError = error{
    InvalidHostname,
    QueryBuildFailed,
    ResponseParseFailed,
    NoAnswer,
    SocketError,
    Timeout,
    TlsError,
    HttpError,
};

pub const Protocol = enum {
    udp,
    tcp,
    https,
};

/// DNS Resolver - generic over socket type (UDP/TCP only)
///
/// Type parameters:
///   - `Socket`: must satisfy `runtime.socket.from` contract
///   - `DomainResolver`: custom resolver consulted before upstream DNS.
///     Pass `void` to disable (zero overhead).
///
/// For DoH support, use `ResolverWithTls` instead.
pub fn Resolver(comptime Socket: type, comptime DomainResolver: type) type {
    return ResolverImpl(Socket, void, void, DomainResolver);
}

/// DNS Resolver with TLS support (UDP/TCP/HTTPS)
///
/// Type parameters:
///   - `Socket`: must satisfy `runtime.socket.from` contract
///   - `Crypto`: crypto primitives (must satisfy `runtime.crypto.suite` contract)
///   - `Rng`:    random number generator (must provide `fill([]u8) void`)
///   - `Mutex`:  mutex type (must satisfy `runtime.sync.Mutex` contract)
///   - `DomainResolver`: custom resolver consulted before upstream DNS.
///     Pass `void` to disable (zero overhead).
pub fn ResolverWithTls(comptime Socket: type, comptime Crypto: type, comptime Rng: type, comptime Mutex: type, comptime DomainResolver: type) type {
    const SConn = conn_mod.SocketConn(Socket);
    return ResolverImpl(Socket, tls.Client(SConn, Crypto, Rng, Mutex), Crypto, DomainResolver);
}

/// Validate DomainResolver interface at comptime.
///
/// A valid DomainResolver must have:
///   fn resolve(*const Self, []const u8) ?[4]u8
///
/// Pass `void` to disable custom resolution (zero overhead).
pub fn validateDomainResolver(comptime Impl: type) type {
    if (Impl == void) return void;

    comptime {
        if (!@hasDecl(Impl, "resolve")) {
            @compileError("DomainResolver must have fn resolve(*const @This(), []const u8) ?[4]u8");
        }
        const resolve_fn = @typeInfo(@TypeOf(Impl.resolve)).@"fn";
        if (resolve_fn.params.len != 2) {
            @compileError("DomainResolver.resolve must take (self, host) — 2 parameters");
        }
        if (resolve_fn.return_type) |ret| {
            if (ret != ?[4]u8) {
                @compileError("DomainResolver.resolve must return ?[4]u8");
            }
        }
    }
    return Impl;
}

pub fn ResolverImpl(comptime Socket: type, comptime TlsClient: type, comptime Crypto: type, comptime DomainResolver: type) type {
    comptime _ = runtime.socket.from(Socket);
    const has_tls = TlsClient != void;
    const has_custom_resolver = DomainResolver != void;

    // Validate DomainResolver at comptime
    const ValidatedResolver = validateDomainResolver(DomainResolver);

    // Get CaStore type from Crypto if available (same logic as tls.Client)
    const CaStore = if (Crypto != void and @hasDecl(Crypto, "x509") and @hasDecl(Crypto.x509, "CaStore"))
        Crypto.x509.CaStore
    else
        void;

    return struct {
        /// DNS server address (for UDP/TCP)
        server: Ipv4Address = .{ 8, 8, 8, 8 }, // Google DNS default

        /// Protocol to use
        protocol: Protocol = .udp,

        /// Timeout in milliseconds
        timeout_ms: u32 = 5000,

        /// DoH server host (for HTTPS protocol)
        doh_host: []const u8 = "dns.alidns.com",

        /// Allocator for TLS (required for DoH)
        allocator: ?std.mem.Allocator = null,

        /// DoH server port (usually 443)
        doh_port: u16 = 443,

        /// Skip TLS certificate verification (for testing)
        skip_cert_verify: bool = false,

        /// CA store for certificate verification (optional)
        /// If null and skip_cert_verify is false, verification may fail
        ca_store: if (CaStore != void) ?CaStore else void = if (CaStore != void) null else {},

        /// Custom domain resolver (consulted before upstream DNS)
        /// Only present when DomainResolver != void
        custom_resolver: if (has_custom_resolver) ?*const ValidatedResolver else void =
            if (has_custom_resolver) null else {},

        const Self = @This();

        /// Resolve hostname to IPv4 address
        pub fn resolve(self: *const Self, hostname: []const u8) DnsError!Ipv4Address {
            // Consult custom resolver first (comptime eliminated when DomainResolver = void)
            if (has_custom_resolver) {
                if (self.custom_resolver) |r| {
                    if (r.resolve(hostname)) |ip| return ip;
                }
            }

            return switch (self.protocol) {
                .udp => self.resolveUdp(hostname),
                .tcp => self.resolveTcp(hostname),
                .https => self.resolveHttps(hostname),
            };
        }

        fn resolveUdp(self: *const Self, hostname: []const u8) DnsError!Ipv4Address {
            var sock = Socket.udp() catch return error.SocketError;
            defer sock.close();

            sock.setRecvTimeout(self.timeout_ms);

            var query_buf: [512]u8 = undefined;
            const query_len = buildQuery(&query_buf, hostname, generateTxId()) catch return error.QueryBuildFailed;

            _ = sock.sendTo(self.server, 53, query_buf[0..query_len]) catch return error.SocketError;

            var response_buf: [512]u8 = undefined;
            const result = sock.recvFrom(&response_buf) catch |err| {
                return switch (err) {
                    error.Timeout => error.Timeout,
                    else => error.SocketError,
                };
            };

            return parseResponse(response_buf[0..result.len]) catch return error.ResponseParseFailed;
        }

        fn resolveTcp(self: *const Self, hostname: []const u8) DnsError!Ipv4Address {
            var sock = Socket.tcp() catch return error.SocketError;
            defer sock.close();

            sock.setRecvTimeout(self.timeout_ms);
            sock.setSendTimeout(self.timeout_ms);

            // Connect to DNS server
            sock.connect(self.server, 53) catch return error.SocketError;

            // Build query
            var query_buf: [514]u8 = undefined; // 2 bytes length prefix + 512 query
            const query_len = buildQuery(query_buf[2..], hostname, generateTxId()) catch return error.QueryBuildFailed;

            // TCP DNS: prepend 2-byte length
            query_buf[0] = @intCast((query_len >> 8) & 0xFF);
            query_buf[1] = @intCast(query_len & 0xFF);

            // Send query
            _ = sock.send(query_buf[0 .. query_len + 2]) catch return error.SocketError;

            // Receive length prefix
            var len_buf: [2]u8 = undefined;
            _ = sock.recv(&len_buf) catch |err| {
                return switch (err) {
                    error.Timeout => error.Timeout,
                    else => error.SocketError,
                };
            };
            const response_len: usize = (@as(usize, len_buf[0]) << 8) | len_buf[1];

            // Receive response
            var response_buf: [512]u8 = undefined;
            if (response_len > response_buf.len) return error.ResponseParseFailed;

            var total_read: usize = 0;
            while (total_read < response_len) {
                const n = sock.recv(response_buf[total_read..response_len]) catch |err| {
                    return switch (err) {
                        error.Timeout => error.Timeout,
                        else => error.SocketError,
                    };
                };
                if (n == 0) break;
                total_read += n;
            }

            // Parse response
            return parseResponse(response_buf[0..total_read]) catch return error.ResponseParseFailed;
        }

        fn resolveHttps(self: *const Self, hostname: []const u8) DnsError!Ipv4Address {
            if (!has_tls) return error.TlsError;

            const allocator = self.allocator orelse return error.TlsError;

            var query_buf: [512]u8 = undefined;
            const query_len = buildQuery(&query_buf, hostname, generateTxId()) catch return error.QueryBuildFailed;
            const query_data = query_buf[0..query_len];

            const doh_ip = self.resolveDohServer() catch return error.HttpError;

            var sock = Socket.tcp() catch return error.SocketError;
            errdefer sock.close();

            sock.setRecvTimeout(self.timeout_ms);
            sock.setSendTimeout(self.timeout_ms);
            sock.connect(doh_ip, self.doh_port) catch return error.SocketError;

            const SConn = conn_mod.SocketConn(Socket);
            var socket_conn = SConn.init(&sock);

            var tls_client = TlsClient.init(&socket_conn, if (CaStore != void) .{
                .allocator = allocator,
                .hostname = self.doh_host,
                .skip_verify = self.skip_cert_verify,
                .ca_store = self.ca_store,
                .timeout_ms = self.timeout_ms,
            } else .{
                .allocator = allocator,
                .hostname = self.doh_host,
                .skip_verify = self.skip_cert_verify,
                .timeout_ms = self.timeout_ms,
            }) catch return error.TlsError;
            defer tls_client.deinit();

            tls_client.connect() catch return error.TlsError;

            var request_buf: [1024]u8 = undefined;
            const request = buildHttpRequest(&request_buf, self.doh_host, query_data) catch return error.HttpError;

            _ = tls_client.send(request) catch return error.TlsError;

            var response_buf: [2048]u8 = undefined;
            var total_received: usize = 0;

            while (total_received < response_buf.len) {
                const n = tls_client.recv(response_buf[total_received..]) catch {
                    if (total_received > 0) break;
                    return error.TlsError;
                };
                if (n == 0) break;
                total_received += n;

                if (findHttpBody(response_buf[0..total_received])) |_| break;
            }

            const body = findHttpBody(response_buf[0..total_received]) orelse return error.HttpError;

            if (!std.mem.startsWith(u8, response_buf[0..total_received], "HTTP/1.1 200")) {
                return error.HttpError;
            }

            return parseResponse(body) catch return error.ResponseParseFailed;
        }

        fn resolveDohServer(self: *const Self) DnsError!Ipv4Address {
            if (parseIpv4String(self.doh_host)) |ip| return ip;

            var sock = Socket.udp() catch return error.SocketError;
            defer sock.close();

            sock.setRecvTimeout(self.timeout_ms);

            var query_buf: [512]u8 = undefined;
            const query_len = buildQuery(&query_buf, self.doh_host, generateTxId()) catch return error.QueryBuildFailed;

            _ = sock.sendTo(self.server, 53, query_buf[0..query_len]) catch return error.SocketError;

            var response_buf: [512]u8 = undefined;
            const result = sock.recvFrom(&response_buf) catch |err| {
                return switch (err) {
                    error.Timeout => error.Timeout,
                    else => error.SocketError,
                };
            };

            return parseResponse(response_buf[0..result.len]) catch return error.ResponseParseFailed;
        }
    };
}

// ============================================================================
// HTTP Helpers for DoH
// ============================================================================

/// Build HTTP POST request for DoH
pub fn buildHttpRequest(buf: []u8, host: []const u8, dns_query: []const u8) ![]const u8 {
    // HTTP/1.1 POST request with DNS wireformat body
    const header_fmt =
        "POST /dns-query HTTP/1.1\r\n" ++
        "Host: {s}\r\n" ++
        "Content-Type: application/dns-message\r\n" ++
        "Accept: application/dns-message\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";

    const header_len = std.fmt.bufPrint(buf, header_fmt, .{ host, dns_query.len }) catch return error.QueryBuildFailed;

    // Append DNS query body
    if (header_len.len + dns_query.len > buf.len) return error.QueryBuildFailed;

    @memcpy(buf[header_len.len..][0..dns_query.len], dns_query);

    return buf[0 .. header_len.len + dns_query.len];
}

/// Find HTTP body (after \r\n\r\n)
pub fn findHttpBody(data: []const u8) ?[]const u8 {
    const separator = "\r\n\r\n";
    if (std.mem.indexOf(u8, data, separator)) |pos| {
        return data[pos + separator.len ..];
    }
    return null;
}

/// Parse IPv4 string to address
pub fn parseIpv4String(s: []const u8) ?Ipv4Address {
    var result: Ipv4Address = undefined;
    var octet_idx: usize = 0;
    var current: u16 = 0;

    for (s) |c| {
        if (c == '.') {
            if (current > 255 or octet_idx >= 3) return null;
            result[octet_idx] = @intCast(current);
            octet_idx += 1;
            current = 0;
        } else if (c >= '0' and c <= '9') {
            current = current * 10 + (c - '0');
        } else {
            return null; // Not a pure IP address
        }
    }

    if (current > 255 or octet_idx != 3) return null;
    result[3] = @intCast(current);

    return result;
}

// ============================================================================
// DNS Protocol Helpers
// ============================================================================

/// Simple transaction ID generator
var tx_id_counter: u16 = 0x1234;

pub fn generateTxId() u16 {
    tx_id_counter +%= 1;
    return tx_id_counter;
}

/// Build DNS query packet
pub fn buildQuery(buf: []u8, hostname: []const u8, transaction_id: u16) !usize {
    if (hostname.len == 0 or hostname.len > 253) return error.InvalidHostname;

    var pos: usize = 0;

    // Transaction ID
    buf[pos] = @intCast((transaction_id >> 8) & 0xFF);
    buf[pos + 1] = @intCast(transaction_id & 0xFF);
    pos += 2;

    // Flags: standard query, recursion desired
    buf[pos] = 0x01;
    buf[pos + 1] = 0x00;
    pos += 2;

    // Questions: 1
    buf[pos] = 0x00;
    buf[pos + 1] = 0x01;
    pos += 2;

    // Answer RRs: 0
    buf[pos] = 0x00;
    buf[pos + 1] = 0x00;
    pos += 2;

    // Authority RRs: 0
    buf[pos] = 0x00;
    buf[pos + 1] = 0x00;
    pos += 2;

    // Additional RRs: 0
    buf[pos] = 0x00;
    buf[pos + 1] = 0x00;
    pos += 2;

    // Question section: encode hostname
    // "www.google.com" -> "\x03www\x06google\x03com\x00"
    var label_start = pos;
    pos += 1; // reserve space for label length

    for (hostname) |ch| {
        if (ch == '.') {
            // Write label length
            buf[label_start] = @intCast(pos - label_start - 1);
            label_start = pos;
            pos += 1;
        } else {
            buf[pos] = ch;
            pos += 1;
        }
    }
    // Last label
    buf[label_start] = @intCast(pos - label_start - 1);
    buf[pos] = 0x00; // null terminator
    pos += 1;

    // Type: A (1)
    buf[pos] = 0x00;
    buf[pos + 1] = 0x01;
    pos += 2;

    // Class: IN (1)
    buf[pos] = 0x00;
    buf[pos + 1] = 0x01;
    pos += 2;

    return pos;
}

/// Parse DNS response and extract first A record
pub fn parseResponse(data: []const u8) !Ipv4Address {
    if (data.len < 12) return error.ResponseParseFailed;

    // Check response code (lower 4 bits of byte 3)
    const rcode = data[3] & 0x0F;
    if (rcode != 0) return error.NoAnswer;

    // Get answer count
    const answer_count = (@as(u16, data[6]) << 8) | data[7];
    if (answer_count == 0) return error.NoAnswer;

    // Skip header (12 bytes)
    var pos: usize = 12;

    // Skip question section
    while (pos < data.len and data[pos] != 0) {
        if ((data[pos] & 0xC0) == 0xC0) {
            // Compression pointer
            pos += 2;
            break;
        }
        pos += @as(usize, data[pos]) + 1;
    }
    if (pos < data.len and data[pos] == 0) pos += 1;
    pos += 4; // Skip QTYPE and QCLASS

    // Parse answers
    var i: u16 = 0;
    while (i < answer_count and pos + 12 <= data.len) : (i += 1) {
        // Skip name (handle compression)
        if ((data[pos] & 0xC0) == 0xC0) {
            pos += 2;
        } else {
            while (pos < data.len and data[pos] != 0) {
                pos += @as(usize, data[pos]) + 1;
            }
            pos += 1;
        }

        if (pos + 10 > data.len) break;

        const rtype = (@as(u16, data[pos]) << 8) | data[pos + 1];
        pos += 2;
        // Skip class
        pos += 2;
        // Skip TTL
        pos += 4;
        const rdlength = (@as(u16, data[pos]) << 8) | data[pos + 1];
        pos += 2;

        // Type A (1) with 4-byte address
        if (rtype == 1 and rdlength == 4 and pos + 4 <= data.len) {
            return .{ data[pos], data[pos + 1], data[pos + 2], data[pos + 3] };
        }

        pos += rdlength;
    }

    return error.NoAnswer;
}

/// Format IPv4 address as string
pub fn formatIpv4(addr: Ipv4Address, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ addr[0], addr[1], addr[2], addr[3] }) catch "?.?.?.?";
}

// ============================================================================
// Tests
// ============================================================================

// ============================================================================
// DomainResolver Tests
// ============================================================================

pub const TestMockSocket = struct {
    pub fn udp() runtime.socket.Error!@This() {
        return .{};
    }
    pub fn tcp() runtime.socket.Error!@This() {
        return .{};
    }
    pub fn close(_: *@This()) void {}
    pub fn connect(_: *@This(), _: [4]u8, _: u16) runtime.socket.Error!void {}
    pub fn send(_: *@This(), _: []const u8) runtime.socket.Error!usize {
        return 0;
    }
    pub fn recv(_: *@This(), _: []u8) runtime.socket.Error!usize {
        return 0;
    }
    pub fn sendTo(_: *@This(), _: [4]u8, _: u16, _: []const u8) runtime.socket.Error!usize {
        return 0;
    }
    pub fn recvFrom(_: *@This(), _: []u8) runtime.socket.Error!runtime.socket.RecvFromResult {
        return .{ .len = 0, .src_addr = .{ 0, 0, 0, 0 }, .src_port = 0 };
    }
    pub fn setRecvTimeout(_: *@This(), _: u32) void {}
    pub fn setSendTimeout(_: *@This(), _: u32) void {}
    pub fn setTcpNoDelay(_: *@This(), _: bool) void {}
    pub fn getFd(_: *@This()) i32 {
        return 0;
    }
    pub fn setNonBlocking(_: *@This(), _: bool) runtime.socket.Error!void {}
    pub fn bind(_: *@This(), _: [4]u8, _: u16) runtime.socket.Error!void {}
    pub fn getBoundPort(_: *@This()) runtime.socket.Error!u16 {
        return 0;
    }
    pub fn listen(_: *@This()) runtime.socket.Error!void {}
    pub fn accept(_: *@This()) runtime.socket.Error!@This() {
        return .{};
    }
};

// ============================================================================
// Real Network Tests (using runtime.std.Socket)
// ============================================================================

pub fn isAliDnsIp(ip: Ipv4Address) bool {
    return std.mem.eql(u8, &ip, &Servers.alidns) or std.mem.eql(u8, &ip, &Servers.alidns2);
}

// =========================================================================
// DoH (DNS over HTTPS) tests — requires TLS + Crypto
// =========================================================================
