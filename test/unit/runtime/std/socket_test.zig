const std = @import("std");
const embed = @import("embed");
const Std = embed.runtime.std;
const Socket = Std.Socket;
const Thread = Std.Thread;

fn tcpServerEcho(ctx: ?*anyopaque) void {
    const Ctx = struct {
        server: *Socket,
        ok: *std.atomic.Value(u32),
    };

    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    var accepted = c.server.accept() catch return;
    defer accepted.close();

    accepted.setRecvTimeout(1000);
    accepted.setSendTimeout(1000);

    var buf: [64]u8 = undefined;
    const n = accepted.recv(&buf) catch return;
    _ = accepted.send(buf[0..n]) catch return;
    _ = c.ok.fetchAdd(1, .seq_cst);
}

test "std socket tcp loopback echo" {
    var server = try Socket.tcp();
    defer server.close();

    try server.bind(.{ 127, 0, 0, 1 }, 0);
    const port = try server.getBoundPort();
    try server.listen();

    var ok = std.atomic.Value(u32).init(0);
    const Ctx = struct {
        server: *Socket,
        ok: *std.atomic.Value(u32),
    };
    var ctx = Ctx{ .server = &server, .ok = &ok };

    var th = try Thread.spawn(.{}, tcpServerEcho, @ptrCast(&ctx));

    var client = try Socket.tcp();
    defer client.close();
    client.setRecvTimeout(1000);
    client.setSendTimeout(1000);

    try client.connect(.{ 127, 0, 0, 1 }, port);
    _ = try client.send("ping");

    var buf: [16]u8 = undefined;
    const n = try client.recv(&buf);
    try std.testing.expectEqualStrings("ping", buf[0..n]);

    th.join();
    try std.testing.expectEqual(@as(u32, 1), ok.load(.seq_cst));
}

test "std socket udp recvFrom/sendTo" {
    var server = try Socket.udp();
    defer server.close();
    server.setRecvTimeout(1000);
    server.setSendTimeout(1000);

    try server.bind(.{ 127, 0, 0, 1 }, 0);
    const server_port = try server.getBoundPort();

    var client = try Socket.udp();
    defer client.close();
    client.setRecvTimeout(1000);
    client.setSendTimeout(1000);

    _ = try client.sendTo(.{ 127, 0, 0, 1 }, server_port, "u");

    var recv_buf: [16]u8 = undefined;
    const from = try server.recvFrom(&recv_buf);
    try std.testing.expectEqual(@as(usize, 1), from.len);
    try std.testing.expectEqual(@as(u8, 'u'), recv_buf[0]);

    _ = try server.sendTo(from.src_addr, from.src_port, "ok");

    var client_buf: [16]u8 = undefined;
    const from2 = try client.recvFrom(&client_buf);
    try std.testing.expectEqual(@as(usize, 2), from2.len);
    try std.testing.expectEqualStrings("ok", client_buf[0..2]);
}
