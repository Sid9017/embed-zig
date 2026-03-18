const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const client_mod = embed.pkg.net.ws.client;
const ws = embed.pkg.net.ws;
const frame = ws.frame;
const conn_mod = embed.pkg.net.conn;

const MockConn = struct {
    recv_data: []const u8,
    recv_pos: usize = 0,
    sent_buf: [4096]u8 = undefined,
    sent_len: usize = 0,

    pub fn write(self: *MockConn, data: []const u8) conn_mod.Error!usize {
        if (self.sent_len + data.len > self.sent_buf.len) return error.WriteFailed;
        @memcpy(self.sent_buf[self.sent_len..][0..data.len], data);
        self.sent_len += data.len;
        return data.len;
    }

    pub fn read(self: *MockConn, buf: []u8) conn_mod.Error!usize {
        if (self.recv_pos >= self.recv_data.len) return error.Closed;
        const available = self.recv_data.len - self.recv_pos;
        const n = @min(available, buf.len);
        @memcpy(buf[0..n], self.recv_data[self.recv_pos..][0..n]);
        self.recv_pos += n;
        return n;
    }

    pub fn close(_: *MockConn) void {}

    comptime {
        _ = conn_mod.from(MockConn);
    }
};

fn deterministicRng(buf: []u8) void {
    for (buf, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }
}

fn buildServerFrame(allocator: std.mem.Allocator, opcode: frame.Opcode, payload: []const u8) ![]u8 {
    var hdr_buf: [frame.MAX_HEADER_SIZE]u8 = undefined;
    const hdr_len = frame.encodeHeader(&hdr_buf, opcode, payload.len, true, null);
    const total = hdr_len + payload.len;
    const buf = try allocator.alloc(u8, total);
    @memcpy(buf[0..hdr_len], hdr_buf[0..hdr_len]);
    @memcpy(buf[hdr_len..], payload);
    return buf;
}

test "MockConn send + recv roundtrip" {
    const allocator = std.testing.allocator;

    const server_frame = try buildServerFrame(allocator, .text, "hello");
    defer allocator.free(server_frame);

    var mock = MockConn{ .recv_data = server_frame };
    var client = try client_mod.Client(MockConn).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    try client.sendText("hello");

    const msg = (try client.recv()) orelse return error.InvalidResponse;
    try std.testing.expectEqual(client_mod.MessageType.text, msg.type);
    try std.testing.expectEqualSlices(u8, "hello", msg.payload);
}

test "sendBinary + recv binary" {
    const allocator = std.testing.allocator;
    const binary_data = [_]u8{ 0x00, 0x01, 0x02, 0xFF, 0xFE };

    const server_frame = try buildServerFrame(allocator, .binary, &binary_data);
    defer allocator.free(server_frame);

    var mock = MockConn{ .recv_data = server_frame };
    var client = try client_mod.Client(MockConn).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    try client.sendBinary(&binary_data);

    const msg = (try client.recv()) orelse return error.InvalidResponse;
    try std.testing.expectEqual(client_mod.MessageType.binary, msg.type);
    try std.testing.expectEqualSlices(u8, &binary_data, msg.payload);
}

test "auto pong on ping" {
    const allocator = std.testing.allocator;

    const ping_frame = try buildServerFrame(allocator, .ping, "");
    defer allocator.free(ping_frame);

    const text_frame = try buildServerFrame(allocator, .text, "after_ping");
    defer allocator.free(text_frame);

    const combined = try allocator.alloc(u8, ping_frame.len + text_frame.len);
    defer allocator.free(combined);
    @memcpy(combined[0..ping_frame.len], ping_frame);
    @memcpy(combined[ping_frame.len..], text_frame);

    var mock = MockConn{ .recv_data = combined };
    var client = try client_mod.Client(MockConn).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    const ping_msg = (try client.recv()) orelse return error.InvalidResponse;
    try std.testing.expectEqual(client_mod.MessageType.ping, ping_msg.type);

    const sent = mock.sent_buf[0..mock.sent_len];
    try std.testing.expect(sent.len > 0);
    try std.testing.expectEqual(@as(u8, 0x8A), sent[0]);

    const text_msg = (try client.recv()) orelse return error.InvalidResponse;
    try std.testing.expectEqual(client_mod.MessageType.text, text_msg.type);
    try std.testing.expectEqualSlices(u8, "after_ping", text_msg.payload);
}

test "recv close returns null" {
    const allocator = std.testing.allocator;

    const close_payload = [2]u8{ 0x03, 0xE8 };
    const close_frame = try buildServerFrame(allocator, .close, &close_payload);
    defer allocator.free(close_frame);

    var mock = MockConn{ .recv_data = close_frame };
    var client = try client_mod.Client(MockConn).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    const result = try client.recv();
    try std.testing.expectEqual(@as(?client_mod.Message, null), result);
}

test "sendClose sends correct close frame" {
    const allocator = std.testing.allocator;

    var mock = MockConn{ .recv_data = "" };
    var client = try client_mod.Client(MockConn).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    try client.sendClose(1000);

    const sent = mock.sent_buf[0..mock.sent_len];
    try std.testing.expect(sent.len >= 2);

    try std.testing.expectEqual(@as(u8, 0x88), sent[0]);
    try std.testing.expectEqual(@as(u8, 0x82), sent[1]);

    const mask_key = sent[2..6].*;
    var status_bytes = [2]u8{ sent[6], sent[7] };
    ws.frame.applyMask(&status_bytes, mask_key);

    const status = @as(u16, status_bytes[0]) << 8 | @as(u16, status_bytes[1]);
    try std.testing.expectEqual(@as(u16, 1000), status);
}

test "recv on closed client returns null" {
    const allocator = std.testing.allocator;

    var mock = MockConn{ .recv_data = "" };
    var client = try client_mod.Client(MockConn).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    client.close();
    const result = try client.recv();
    try std.testing.expectEqual(@as(?client_mod.Message, null), result);
}

test "sendText on closed client returns error" {
    const allocator = std.testing.allocator;

    var mock = MockConn{ .recv_data = "" };
    var client = try client_mod.Client(MockConn).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    client.state = .closed;
    try std.testing.expectError(error.Closed, client.sendText("hello"));
}
