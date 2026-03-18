const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const base64 = embed.pkg.net.ws.base64;

test "encode empty" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "", base64.encode(&out, ""));
}

test "encode single byte" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "YQ==", base64.encode(&out, "a"));
}

test "encode two bytes" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "YWI=", base64.encode(&out, "ab"));
}

test "encode three bytes" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "YWJj", base64.encode(&out, "abc"));
}

test "encode WebSocket key" {
    const key = [16]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 };
    var out: [24]u8 = undefined;
    const encoded = base64.encode(&out, &key);
    try std.testing.expectEqual(@as(usize, 24), encoded.len);
}

test "RFC 6455 Sec-WebSocket-Accept" {
    const sha1_mod = embed.pkg.net.ws.sha1;
    const key_with_guid = "dGhlIHNhbXBsZSBub25jZQ==" ++ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    const digest = sha1_mod.hash(key_with_guid);
    var out: [28]u8 = undefined;
    const accept = base64.encode(&out, &digest);
    try std.testing.expectEqualSlices(u8, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "decode roundtrip" {
    const original = "Hello, WebSocket!";
    var enc_buf: [base64.encodedLen(original.len)]u8 = undefined;
    const encoded = base64.encode(&enc_buf, original);

    var dec_buf: [original.len]u8 = undefined;
    const decoded = try base64.decode(&dec_buf, encoded);
    try std.testing.expectEqualSlices(u8, original, decoded);
}

test "decode invalid padding" {
    var out: [4]u8 = undefined;
    try std.testing.expectError(error.InvalidPadding, base64.decode(&out, "abc"));
}

test "decode invalid character" {
    var out: [4]u8 = undefined;
    try std.testing.expectError(error.InvalidCharacter, base64.decode(&out, "ab!d"));
}
