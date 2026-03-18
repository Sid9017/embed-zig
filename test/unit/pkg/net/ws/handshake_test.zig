const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const handshake = embed.pkg.net.ws.handshake;

test "buildRequest basic" {
    var buf: [512]u8 = undefined;
    const req = try handshake.buildRequest(&buf, "echo.websocket.org", "/", "dGhlIHNhbXBsZSBub25jZQ==", null);

    try std.testing.expect(std.mem.indexOf(u8, req, "GET / HTTP/1.1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Host: echo.websocket.org\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Upgrade: websocket\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Connection: Upgrade\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Sec-WebSocket-Version: 13\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, req, "\r\n\r\n"));
}

test "validateResponse 101" {
    var expected_accept: [28]u8 = undefined;
    handshake.computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &expected_accept);

    var response_buf: [256]u8 = undefined;
    var writer = handshake.BufWriter{ .buf = &response_buf };
    try writer.writeSlice("HTTP/1.1 101 Switching Protocols\r\n");
    try writer.writeSlice("Upgrade: websocket\r\n");
    try writer.writeSlice("Connection: Upgrade\r\n");
    try writer.writeSlice("Sec-WebSocket-Accept: ");
    try writer.writeSlice(&expected_accept);
    try writer.writeSlice("\r\n\r\n");

    const consumed = try handshake.validateResponse(response_buf[0..writer.pos], &expected_accept);
    try std.testing.expectEqual(writer.pos, consumed);
}

test "validateResponse non-101 error" {
    const resp = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n";
    try std.testing.expectError(error.HandshakeFailed, handshake.validateResponse(resp, "dummy_accept_value_1234567"));
}

test "buildRequest extra headers" {
    var buf: [1024]u8 = undefined;
    const headers = [_][2][]const u8{
        .{ "X-Api-App-Key", "test-key" },
        .{ "X-Custom", "value" },
    };
    const req = try handshake.buildRequest(&buf, "api.example.com", "/ws", "dGhlIHNhbXBsZSBub25jZQ==", &headers);

    try std.testing.expect(std.mem.indexOf(u8, req, "X-Api-App-Key: test-key\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "X-Custom: value\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "GET /ws HTTP/1.1\r\n") != null);
}

test "computeAcceptKey RFC 6455 example" {
    var accept: [28]u8 = undefined;
    handshake.computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &accept);
    try std.testing.expectEqualSlices(u8, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}
