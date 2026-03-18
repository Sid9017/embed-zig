const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const Std = embed.runtime.std;
const stream = embed.pkg.net.tls.stream;
const conn_mod = embed.pkg.net.conn;

const TestMockConn = struct {
    const Self = @This();
    closed: bool = false,

    pub fn read(_: *Self, _: []u8) conn_mod.Error!usize {
        return conn_mod.Error.ReadFailed;
    }
    pub fn write(_: *Self, _: []const u8) conn_mod.Error!usize {
        return conn_mod.Error.WriteFailed;
    }
    pub fn close(self: *Self) void {
        self.closed = true;
    }
};

test "Stream satisfies Conn contract" {
    const Runtime = Std;

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

    const TlsStream = stream.Stream(MockConn, Runtime);
    _ = conn_mod.from(TlsStream);
}

test "Stream init and deinit" {
    const Runtime = Std;

    var conn = TestMockConn{};
    var s = try stream.Stream(TestMockConn, Runtime).init(&conn, std.testing.allocator, "example.com", .{});
    defer s.deinit();

    try std.testing.expect(s.client == null);
}

test "Stream read before handshake returns Closed" {
    const Runtime = Std;

    var conn = TestMockConn{};
    var s = try stream.Stream(TestMockConn, Runtime).init(&conn, std.testing.allocator, "example.com", .{});
    defer s.deinit();

    var buf: [64]u8 = undefined;
    try std.testing.expectError(conn_mod.Error.Closed, s.read(&buf));
}

test "Stream write before handshake returns Closed" {
    const Runtime = Std;

    var conn = TestMockConn{};
    var s = try stream.Stream(TestMockConn, Runtime).init(&conn, std.testing.allocator, "example.com", .{});
    defer s.deinit();

    try std.testing.expectError(conn_mod.Error.Closed, s.write("hello"));
}

test "Stream close before handshake is safe" {
    const Runtime = Std;

    var conn = TestMockConn{};
    var s = try stream.Stream(TestMockConn, Runtime).init(&conn, std.testing.allocator, "example.com", .{});
    defer s.deinit();

    s.close();
    try std.testing.expect(s.client == null);
}

test "Stream deinit is idempotent" {
    const Runtime = Std;

    var conn = TestMockConn{};
    var s = try stream.Stream(TestMockConn, Runtime).init(&conn, std.testing.allocator, "example.com", .{});

    s.deinit();
    s.deinit();
}

test "Stream options defaults" {
    const opts: stream.Options = .{};
    try std.testing.expectEqual(false, opts.skip_cert_verify);
    try std.testing.expectEqual(@as(u32, 30000), opts.timeout_ms);
}

test "Stream options custom" {
    const opts: stream.Options = .{
        .skip_cert_verify = true,
        .timeout_ms = 5000,
    };
    try std.testing.expectEqual(true, opts.skip_cert_verify);
    try std.testing.expectEqual(@as(u32, 5000), opts.timeout_ms);
}

test "Stream preserves hostname and allocator" {
    const Runtime = Std;

    var conn = TestMockConn{};
    var s = try stream.Stream(TestMockConn, Runtime).init(&conn, std.testing.allocator, "my.host.com", .{});
    defer s.deinit();

    try std.testing.expectEqualStrings("my.host.com", s.hostname);
}
