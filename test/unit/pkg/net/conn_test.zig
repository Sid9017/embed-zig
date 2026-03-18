const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const conn = embed.pkg.net.conn;
const runtime = embed.runtime;

test "Conn contract validation with valid type" {
    const ValidConn = struct {
        const Self = @This();
        pub fn read(_: *Self, _: []u8) conn.Error!usize {
            return 0;
        }
        pub fn write(_: *Self, _: []const u8) conn.Error!usize {
            return 0;
        }
        pub fn close(_: *Self) void {}
    };
    _ = conn.from(ValidConn);
}

test "Conn conn.Error values are distinct" {
    try testing.expect(@intFromError(conn.Error.ReadFailed) != @intFromError(conn.Error.WriteFailed));
    try testing.expect(@intFromError(conn.Error.ReadFailed) != @intFromError(conn.Error.Closed));
    try testing.expect(@intFromError(conn.Error.ReadFailed) != @intFromError(conn.Error.Timeout));
    try testing.expect(@intFromError(conn.Error.WriteFailed) != @intFromError(conn.Error.Closed));
    try testing.expect(@intFromError(conn.Error.WriteFailed) != @intFromError(conn.Error.Timeout));
    try testing.expect(@intFromError(conn.Error.Closed) != @intFromError(conn.Error.Timeout));
}

test "Conn conn.from returns the same type" {
    const MyConn = struct {
        const Self = @This();
        pub fn read(_: *Self, _: []u8) conn.Error!usize {
            return 0;
        }
        pub fn write(_: *Self, _: []const u8) conn.Error!usize {
            return 0;
        }
        pub fn close(_: *Self) void {}
    };
    const Validated = conn.from(MyConn);
    try @import("std").testing.expect(Validated == MyConn);
}

test "SocketConn satisfies Conn contract" {
    const Socket = runtime.std.Socket;
    const Adapted = conn.SocketConn(Socket);
    _ = conn.from(Adapted);
}

test "SocketConn read/write/close over TCP loopback" {
    const Socket = runtime.std.Socket;

    var listener = try Socket.tcp();
    defer listener.close();
    try listener.bind(.{ 127, 0, 0, 1 }, 0);
    try listener.listen();
    const port = try listener.getBoundPort();

    var client_sock = try Socket.tcp();
    try client_sock.connect(.{ 127, 0, 0, 1 }, port);

    var server_sock = try listener.accept();
    defer server_sock.close();

    var client_conn = conn.SocketConn(Socket).init(&client_sock);
    var server_conn = conn.SocketConn(Socket).init(&server_sock);

    const msg = "hello via SocketConn";
    const written = try client_conn.write(msg);
    try testing.expectEqual(msg.len, written);

    var buf: [64]u8 = undefined;
    const n = try server_conn.read(&buf);
    try testing.expectEqualSlices(u8, msg, buf[0..n]);

    client_conn.close();
}

test "SocketConn maps Closed error" {
    const Socket = runtime.std.Socket;

    var listener = try Socket.tcp();
    defer listener.close();
    try listener.bind(.{ 127, 0, 0, 1 }, 0);
    try listener.listen();
    const port = try listener.getBoundPort();

    var client_sock = try Socket.tcp();
    try client_sock.connect(.{ 127, 0, 0, 1 }, port);

    var server_sock = try listener.accept();
    server_sock.close();

    var client_conn = conn.SocketConn(Socket).init(&client_sock);
    defer client_conn.close();

    var buf: [64]u8 = undefined;
    const result = client_conn.read(&buf);
    try testing.expectError(conn.Error.Closed, result);
}

test "SocketConn maps Timeout error" {
    const Socket = runtime.std.Socket;

    var listener = try Socket.tcp();
    defer listener.close();
    try listener.bind(.{ 127, 0, 0, 1 }, 0);
    try listener.listen();
    const port = try listener.getBoundPort();

    var client_sock = try Socket.tcp();
    try client_sock.connect(.{ 127, 0, 0, 1 }, port);
    defer client_sock.close();

    var server_sock = try listener.accept();
    defer server_sock.close();

    client_sock.setRecvTimeout(50);
    var client_conn = conn.SocketConn(Socket).init(&client_sock);

    var buf: [64]u8 = undefined;
    const result = client_conn.read(&buf);
    try testing.expectError(conn.Error.Timeout, result);
}
