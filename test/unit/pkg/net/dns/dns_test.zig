const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const dns = embed.pkg.net.dns;
const Std = embed.runtime.std;

fn isAliDnsIp(ip: dns.Ipv4Address) bool {
    return std.mem.eql(u8, &ip, &dns.Servers.alidns) or std.mem.eql(u8, &ip, &dns.Servers.alidns2);
}

fn requireLiveDnsTests() !void {
    const marker = std.process.getEnvVarOwned(testing.allocator, "EMBED_ZIG_RUN_LIVE_DNS_TESTS") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(marker);

    if (!std.mem.eql(u8, marker, "1")) {
        return error.SkipZigTest;
    }
}

test "buildQuery" {
    var buf: [512]u8 = undefined;
    const len = try dns.buildQuery(&buf, "www.google.com", 0x1234);

    // Check transaction ID
    try std.testing.expectEqual(@as(u8, 0x12), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x34), buf[1]);

    // Check query is reasonable length
    try std.testing.expect(len > 12);
    try std.testing.expect(len < 100);
}

test "parseIpv4String" {
    const ip = dns.parseIpv4String("192.168.1.1").?;
    try std.testing.expectEqual(@as(u8, 192), ip[0]);
    try std.testing.expectEqual(@as(u8, 168), ip[1]);
    try std.testing.expectEqual(@as(u8, 1), ip[2]);
    try std.testing.expectEqual(@as(u8, 1), ip[3]);

    // Not an IP
    try std.testing.expect(dns.parseIpv4String("dns.google.com") == null);
}

test "buildHttpRequest" {
    var buf: [1024]u8 = undefined;
    const dns_query = [_]u8{ 0x00, 0x01, 0x02 };
    const request = try dns.buildHttpRequest(&buf, "dns.google.com", &dns_query);

    try std.testing.expect(std.mem.indexOf(u8, request, "POST /dns-query") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "Host: dns.google.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "Content-Length: 3") != null);
}

test "findHttpBody" {
    const response = "HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\n\r\nBODY";
    const body = dns.findHttpBody(response).?;
    try std.testing.expectEqualStrings("BODY", body);

    // No body separator
    try std.testing.expect(dns.findHttpBody("incomplete") == null);
}

test "validateDomainResolver: void is valid" {
    const V = dns.validateDomainResolver(void);
    try std.testing.expect(V == void);
}

test "validateDomainResolver: valid resolver" {
    const MockResolver = struct {
        suffix: []const u8,

        pub fn resolve(self: *const @This(), host: []const u8) ?[4]u8 {
            if (std.mem.endsWith(u8, host, self.suffix)) {
                return .{ 10, 0, 0, 1 };
            }
            return null;
        }
    };

    const Validated = dns.validateDomainResolver(MockResolver);
    try std.testing.expect(Validated == MockResolver);

    const resolver = MockResolver{ .suffix = ".zigor.net" };
    try std.testing.expectEqual(@as(?[4]u8, .{ 10, 0, 0, 1 }), resolver.resolve("abc.host.zigor.net"));
    try std.testing.expectEqual(@as(?[4]u8, null), resolver.resolve("www.google.com"));
}

test "Resolver with void DomainResolver: custom_resolver is void (zero overhead)" {
    const R = dns.Resolver(Std, void);
    const fields = @typeInfo(R).@"struct".fields;
    comptime {
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "custom_resolver")) {
                if (f.type != void) @compileError("expected void field");
            }
        }
    }
}

test "Resolver with DomainResolver has custom_resolver field" {
    const MockResolver = struct {
        pub fn resolve(_: *const @This(), host: []const u8) ?[4]u8 {
            if (std.mem.endsWith(u8, host, ".zigor.net")) {
                return .{ 10, 0, 0, 1 };
            }
            return null;
        }
    };

    const R = dns.Resolver(Std, MockResolver);
    try std.testing.expect(@hasField(R, "custom_resolver"));
}

test "UDP resolve dns.alidns.com via 223.5.5.5" {
    try requireLiveDnsTests();
    const R = dns.Resolver(Std, void);
    const resolver = R{ .server = dns.Servers.alidns, .protocol = .udp, .timeout_ms = 5000 };
    const ip = try resolver.resolve("dns.alidns.com");
    try std.testing.expect(isAliDnsIp(ip));
}

test "TCP resolve dns.alidns.com via 223.5.5.5" {
    try requireLiveDnsTests();
    const R = dns.Resolver(Std, void);
    const resolver = R{ .server = dns.Servers.alidns, .protocol = .tcp, .timeout_ms = 5000 };
    const ip = try resolver.resolve("dns.alidns.com");
    try std.testing.expect(isAliDnsIp(ip));
}

test "UDP and TCP resolve dns.alidns.com return same result" {
    try requireLiveDnsTests();
    const R = dns.Resolver(Std, void);
    const udp_resolver = R{ .server = dns.Servers.alidns, .protocol = .udp, .timeout_ms = 5000 };
    const tcp_resolver = R{ .server = dns.Servers.alidns, .protocol = .tcp, .timeout_ms = 5000 };
    const udp_ip = try udp_resolver.resolve("dns.alidns.com");
    const tcp_ip = try tcp_resolver.resolve("dns.alidns.com");
    try std.testing.expect(isAliDnsIp(udp_ip));
    try std.testing.expect(isAliDnsIp(tcp_ip));
}

test "UDP resolve www.baidu.com returns valid IPv4" {
    try requireLiveDnsTests();
    const R = dns.Resolver(Std, void);
    const resolver = R{ .server = dns.Servers.alidns, .protocol = .udp, .timeout_ms = 5000 };
    const ip = try resolver.resolve("www.baidu.com");
    try std.testing.expect(ip[0] != 0);
}

test "TCP resolve www.baidu.com returns valid IPv4" {
    try requireLiveDnsTests();
    const R = dns.Resolver(Std, void);
    const resolver = R{ .server = dns.Servers.alidns, .protocol = .tcp, .timeout_ms = 5000 };
    const ip = try resolver.resolve("www.baidu.com");
    try std.testing.expect(ip[0] != 0);
}

test "UDP resolve via Google DNS 8.8.8.8" {
    try requireLiveDnsTests();
    const R = dns.Resolver(Std, void);
    const resolver = R{ .server = dns.Servers.google, .protocol = .udp, .timeout_ms = 5000 };
    const ip = try resolver.resolve("dns.google");
    try std.testing.expect(ip[0] == 8 and ip[1] == 8);
}

test "UDP resolve nonexistent domain returns error" {
    try requireLiveDnsTests();
    const R = dns.Resolver(Std, void);
    const resolver = R{ .server = dns.Servers.alidns, .protocol = .udp, .timeout_ms = 5000 };
    if (resolver.resolve("this.domain.does.not.exist.invalid")) |_| {
        return error.ExpectedError;
    } else |err| {
        try std.testing.expect(err == error.NoAnswer or err == error.ResponseParseFailed);
    }
}

test "UDP resolve multiple domains sequentially" {
    try requireLiveDnsTests();
    const R = dns.Resolver(Std, void);
    const resolver = R{ .server = dns.Servers.alidns, .protocol = .udp, .timeout_ms = 5000 };

    const domains = [_][]const u8{ "www.google.com", "www.baidu.com", "github.com" };
    for (domains) |domain| {
        const ip = try resolver.resolve(domain);
        try std.testing.expect(ip[0] != 0);
    }
}

test "DomainResolver intercepts before upstream" {
    try requireLiveDnsTests();
    const FakeResolver = struct {
        pub fn resolve(_: *const @This(), host: []const u8) ?[4]u8 {
            if (std.mem.eql(u8, host, "fake.local")) return .{ 10, 0, 0, 99 };
            return null;
        }
    };
    const R = dns.Resolver(Std, FakeResolver);
    const custom = FakeResolver{};
    const resolver = R{
        .server = dns.Servers.alidns,
        .protocol = .udp,
        .timeout_ms = 5000,
        .custom_resolver = &custom,
    };

    const ip = try resolver.resolve("fake.local");
    try std.testing.expectEqual(dns.Ipv4Address{ 10, 0, 0, 99 }, ip);

    const real_ip = try resolver.resolve("dns.alidns.com");
    try std.testing.expect(isAliDnsIp(real_ip));
}

test "UDP resolve via Cloudflare DNS 1.1.1.1" {
    try requireLiveDnsTests();
    const R = dns.Resolver(Std, void);
    const resolver = R{ .server = dns.Servers.cloudflare, .protocol = .udp, .timeout_ms = 5000 };
    const ip = try resolver.resolve("cloudflare.com");
    try std.testing.expect(ip[0] != 0);
}

test "TCP resolve via Cloudflare DNS 1.1.1.1" {
    try requireLiveDnsTests();
    const R = dns.Resolver(Std, void);
    const resolver = R{ .server = dns.Servers.cloudflare, .protocol = .tcp, .timeout_ms = 5000 };
    const ip = try resolver.resolve("cloudflare.com");
    try std.testing.expect(ip[0] != 0);
}

test "UDP resolve dns.google via Google DNS returns 8.8.x.x" {
    try requireLiveDnsTests();
    const R = dns.Resolver(Std, void);
    const resolver = R{ .server = dns.Servers.google, .protocol = .udp, .timeout_ms = 5000 };
    const ip = try resolver.resolve("dns.google");
    try std.testing.expect(ip[0] == 8 and ip[1] == 8);
}

test "formatIpv4 round-trip" {
    const ip = dns.Ipv4Address{ 223, 5, 5, 5 };
    var buf: [16]u8 = undefined;
    const s = dns.formatIpv4(ip, &buf);
    try std.testing.expectEqualStrings("223.5.5.5", s);
}

test "formatIpv4 zeros" {
    var buf: [16]u8 = undefined;
    const s = dns.formatIpv4(.{ 0, 0, 0, 0 }, &buf);
    try std.testing.expectEqualStrings("0.0.0.0", s);
}

test "formatIpv4 max" {
    var buf: [16]u8 = undefined;
    const s = dns.formatIpv4(.{ 255, 255, 255, 255 }, &buf);
    try std.testing.expectEqualStrings("255.255.255.255", s);
}

test "parseResponse: too short" {
    const data = [_]u8{ 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.ResponseParseFailed, dns.parseResponse(&data));
}

test "parseResponse: rcode NXDOMAIN" {
    var data = [_]u8{0} ** 12;
    data[3] = 0x03; // NXDOMAIN
    try std.testing.expectError(error.NoAnswer, dns.parseResponse(&data));
}

test "parseResponse: zero answers" {
    var data = [_]u8{0} ** 12;
    data[2] = 0x81; // QR=1, RD=1
    data[3] = 0x80; // RA=1, rcode=0
    data[6] = 0; // ANCOUNT = 0
    data[7] = 0;
    try std.testing.expectError(error.NoAnswer, dns.parseResponse(&data));
}

test "buildQuery: empty hostname" {
    var buf: [512]u8 = undefined;
    try std.testing.expectError(error.InvalidHostname, dns.buildQuery(&buf, "", 0x1234));
}

test "buildQuery: hostname too long" {
    const long = "a" ** 254;
    var buf: [512]u8 = undefined;
    try std.testing.expectError(error.InvalidHostname, dns.buildQuery(&buf, long, 0x1234));
}

test "buildQuery: single label" {
    var buf: [512]u8 = undefined;
    const len = try dns.buildQuery(&buf, "localhost", 0xABCD);
    try std.testing.expectEqual(@as(u8, 0xAB), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), buf[1]);
    try std.testing.expect(len > 12);
}

test "Servers constants are valid" {
    try std.testing.expectEqual(dns.Ipv4Address{ 223, 5, 5, 5 }, dns.Servers.alidns);
    try std.testing.expectEqual(dns.Ipv4Address{ 223, 6, 6, 6 }, dns.Servers.alidns2);
    try std.testing.expectEqual(dns.Ipv4Address{ 119, 29, 29, 29 }, dns.Servers.dnspod);
    try std.testing.expectEqual(dns.Ipv4Address{ 8, 8, 8, 8 }, dns.Servers.google);
    try std.testing.expectEqual(dns.Ipv4Address{ 8, 8, 4, 4 }, dns.Servers.google2);
    try std.testing.expectEqual(dns.Ipv4Address{ 1, 1, 1, 1 }, dns.Servers.cloudflare);
    try std.testing.expectEqual(dns.Ipv4Address{ 1, 0, 0, 1 }, dns.Servers.cloudflare2);
    try std.testing.expectEqual(dns.Ipv4Address{ 9, 9, 9, 9 }, dns.Servers.quad9);
}

test "DohHosts constants are non-empty" {
    try std.testing.expect(dns.DohHosts.alidns.len > 0);
    try std.testing.expect(dns.DohHosts.google.len > 0);
    try std.testing.expect(dns.DohHosts.cloudflare.len > 0);
}

test "ServerLists have entries" {
    try std.testing.expect(dns.ServerLists.china.len >= 2);
    try std.testing.expect(dns.ServerLists.global.len >= 2);
    try std.testing.expect(dns.ServerLists.mixed.len >= 2);
}

test "concurrent UDP resolves from multiple threads" {
    try requireLiveDnsTests();
    const R = dns.Resolver(Std, void);

    const Worker = struct {
        fn run(domain: []const u8) void {
            const resolver = R{ .server = dns.Servers.alidns, .protocol = .udp, .timeout_ms = 5000 };
            const ip = resolver.resolve(domain) catch return;
            std.debug.assert(ip[0] != 0);
        }
    };

    var threads: [4]std.Thread = undefined;
    const domains = [_][]const u8{ "www.baidu.com", "www.google.com", "github.com", "dns.alidns.com" };
    for (domains, 0..) |domain, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{domain});
    }
    for (&threads) |*t| t.join();
}

test "concurrent TCP resolves from multiple threads" {
    try requireLiveDnsTests();
    const R = dns.Resolver(Std, void);

    const Worker = struct {
        fn run(domain: []const u8) void {
            const resolver = R{ .server = dns.Servers.alidns, .protocol = .tcp, .timeout_ms = 5000 };
            const ip = resolver.resolve(domain) catch return;
            std.debug.assert(ip[0] != 0);
        }
    };

    var threads: [4]std.Thread = undefined;
    const domains = [_][]const u8{ "www.baidu.com", "www.google.com", "github.com", "dns.alidns.com" };
    for (domains, 0..) |domain, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{domain});
    }
    for (&threads) |*t| t.join();
}

test "concurrent mixed UDP+TCP resolves" {
    try requireLiveDnsTests();
    const R = dns.Resolver(Std, void);

    const Worker = struct {
        fn run(proto: dns.Protocol) void {
            const resolver = R{ .server = dns.Servers.alidns, .protocol = proto, .timeout_ms = 5000 };
            const ip = resolver.resolve("dns.alidns.com") catch return;
            std.debug.assert(std.mem.eql(u8, &ip, &dns.Servers.alidns) or std.mem.eql(u8, &ip, &dns.Servers.alidns2));
        }
    };

    var threads: [6]std.Thread = undefined;
    const protos = [_]dns.Protocol{ .udp, .tcp, .udp, .tcp, .udp, .tcp };
    for (protos, 0..) |proto, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{proto});
    }
    for (&threads) |*t| t.join();
}

test "concurrent resolves with different DNS servers" {
    try requireLiveDnsTests();
    const R = dns.Resolver(Std, void);

    const Worker = struct {
        fn run(server: dns.Ipv4Address) void {
            const resolver = R{ .server = server, .protocol = .udp, .timeout_ms = 5000 };
            const ip = resolver.resolve("www.baidu.com") catch return;
            std.debug.assert(ip[0] != 0);
        }
    };

    var threads: [3]std.Thread = undefined;
    const servers = [_]dns.Ipv4Address{ dns.Servers.alidns, dns.Servers.google, dns.Servers.cloudflare };
    for (servers, 0..) |server, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{server});
    }
    for (&threads) |*t| t.join();
}

test "DoH resolve dns.alidns.com via AliDNS" {
    try requireLiveDnsTests();
    const R = dns.ResolverWithTls(Std, void);
    const resolver = R{
        .server = dns.Servers.alidns,
        .protocol = .https,
        .doh_host = dns.DohHosts.alidns,
        .doh_port = 443,
        .skip_cert_verify = true,
        .allocator = std.testing.allocator,
        .timeout_ms = 15000,
    };
    const ip = resolver.resolve("dns.alidns.com") catch |err| switch (err) {
        error.TlsError, error.Timeout, error.SocketError, error.HttpError => return,
        else => return err,
    };
    try std.testing.expect(isAliDnsIp(ip));
}

test "DoH resolve www.baidu.com via AliDNS" {
    try requireLiveDnsTests();
    const R = dns.ResolverWithTls(Std, void);
    const resolver = R{
        .server = dns.Servers.alidns,
        .protocol = .https,
        .doh_host = dns.DohHosts.alidns,
        .doh_port = 443,
        .skip_cert_verify = true,
        .allocator = std.testing.allocator,
        .timeout_ms = 15000,
    };
    const ip = resolver.resolve("www.baidu.com") catch |err| switch (err) {
        error.TlsError, error.Timeout, error.SocketError, error.HttpError => return,
        else => return err,
    };
    try std.testing.expect(ip[0] != 0);
}

test "DoH resolve via Cloudflare" {
    try requireLiveDnsTests();
    const R = dns.ResolverWithTls(Std, void);
    const resolver = R{
        .server = dns.Servers.cloudflare,
        .protocol = .https,
        .doh_host = dns.DohHosts.cloudflare,
        .doh_port = 443,
        .skip_cert_verify = true,
        .allocator = std.testing.allocator,
        .timeout_ms = 15000,
    };
    const ip = resolver.resolve("www.google.com") catch |err| switch (err) {
        error.TlsError, error.Timeout, error.SocketError, error.HttpError => return,
        else => return err,
    };
    try std.testing.expect(ip[0] != 0);
}

test "DoH resolve via Google" {
    try requireLiveDnsTests();
    const R = dns.ResolverWithTls(Std, void);
    const resolver = R{
        .server = dns.Servers.google,
        .protocol = .https,
        .doh_host = dns.DohHosts.google,
        .doh_port = 443,
        .skip_cert_verify = true,
        .allocator = std.testing.allocator,
        .timeout_ms = 15000,
    };
    const ip = resolver.resolve("github.com") catch |err| switch (err) {
        error.TlsError, error.Timeout, error.SocketError, error.HttpError => return,
        else => return err,
    };
    try std.testing.expect(ip[0] != 0);
}

test "DoH nonexistent domain returns error" {
    try requireLiveDnsTests();
    const R = dns.ResolverWithTls(Std, void);
    const resolver = R{
        .server = dns.Servers.alidns,
        .protocol = .https,
        .doh_host = dns.DohHosts.alidns,
        .doh_port = 443,
        .skip_cert_verify = true,
        .allocator = std.testing.allocator,
        .timeout_ms = 15000,
    };
    if (resolver.resolve("this.domain.does.not.exist.invalid")) |_| {
        return error.ExpectedError;
    } else |err| {
        try std.testing.expect(err == error.NoAnswer or err == error.ResponseParseFailed or
            err == error.TlsError or err == error.Timeout or err == error.HttpError);
    }
}

test "concurrent DoH resolves from multiple threads" {
    try requireLiveDnsTests();
    const R = dns.ResolverWithTls(Std, void);

    const Worker = struct {
        fn run(domain: []const u8) void {
            const resolver = R{
                .server = dns.Servers.alidns,
                .protocol = .https,
                .doh_host = dns.DohHosts.alidns,
                .doh_port = 443,
                .skip_cert_verify = true,
                .allocator = std.testing.allocator,
                .timeout_ms = 15000,
            };
            const ip = resolver.resolve(domain) catch return;
            std.debug.assert(ip[0] != 0);
        }
    };

    var threads: [3]std.Thread = undefined;
    const domains = [_][]const u8{ "www.baidu.com", "www.google.com", "github.com" };
    for (domains, 0..) |domain, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{domain});
    }
    for (&threads) |*t| t.join();
}
