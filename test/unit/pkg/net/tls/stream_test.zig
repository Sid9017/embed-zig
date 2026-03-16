const std = @import("std");
const testing = std.testing;
const module = @import("embed").pkg.net.tls.stream;
const Options = module.Options;
const Stream = module.Stream;
const runtime = module.runtime;
const conn_mod = module.conn_mod;
const client_mod = module.client_mod;
const common = module.common;
const TestMockConn = module.TestMockConn;

test "Stream satisfies Conn contract" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    const MockConn = struct {
        const Self = @This();
        pub fn read(_: *Self, _: []u8) conn_mod.Error!usize {
            return 0;
        }
        pub fn write(_: *Self, _: []const u8) conn_mod.Error!usize {
            return 0;
        }
        pub fn close(_: *Self) void {}
    };

    const TlsStream = Stream(MockConn, Crypto, Rng, Mutex);
    _ = conn_mod.from(TlsStream);
}

test "Stream init and deinit" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var conn = TestMockConn{};
    var s = try Stream(TestMockConn, Crypto, Rng, Mutex).init(&conn, std.testing.allocator, "example.com", .{});
    defer s.deinit();

    try std.testing.expect(s.client == null);
}

test "Stream read before handshake returns Closed" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var conn = TestMockConn{};
    var s = try Stream(TestMockConn, Crypto, Rng, Mutex).init(&conn, std.testing.allocator, "example.com", .{});
    defer s.deinit();

    var buf: [64]u8 = undefined;
    try std.testing.expectError(conn_mod.Error.Closed, s.read(&buf));
}

test "Stream write before handshake returns Closed" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var conn = TestMockConn{};
    var s = try Stream(TestMockConn, Crypto, Rng, Mutex).init(&conn, std.testing.allocator, "example.com", .{});
    defer s.deinit();

    try std.testing.expectError(conn_mod.Error.Closed, s.write("hello"));
}

test "Stream close before handshake is safe" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var conn = TestMockConn{};
    var s = try Stream(TestMockConn, Crypto, Rng, Mutex).init(&conn, std.testing.allocator, "example.com", .{});
    defer s.deinit();

    s.close();
    try std.testing.expect(s.client == null);
}

test "Stream deinit is idempotent" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var conn = TestMockConn{};
    var s = try Stream(TestMockConn, Crypto, Rng, Mutex).init(&conn, std.testing.allocator, "example.com", .{});

    s.deinit();
    s.deinit();
}

test "Stream options defaults" {
    const opts: Options = .{};
    try std.testing.expectEqual(false, opts.skip_cert_verify);
    try std.testing.expectEqual(@as(u32, 30000), opts.timeout_ms);
}

test "Stream options custom" {
    const opts: Options = .{
        .skip_cert_verify = true,
        .timeout_ms = 5000,
    };
    try std.testing.expectEqual(true, opts.skip_cert_verify);
    try std.testing.expectEqual(@as(u32, 5000), opts.timeout_ms);
}

test "Stream preserves hostname and allocator" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var conn = TestMockConn{};
    var s = try Stream(TestMockConn, Crypto, Rng, Mutex).init(&conn, std.testing.allocator, "my.host.com", .{});
    defer s.deinit();

    try std.testing.expectEqualStrings("my.host.com", s.hostname);
}
