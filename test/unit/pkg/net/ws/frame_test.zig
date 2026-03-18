const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const frame = embed.pkg.net.ws.frame;

test "encode text frame" {
    var buf: [frame.MAX_HEADER_SIZE + 5]u8 = undefined;
    const mask = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
    const hdr_len = frame.encodeHeader(&buf, .text, 5, true, mask);

    try std.testing.expectEqual(@as(u8, 0x81), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x85), buf[1]);
    try std.testing.expectEqualSlices(u8, &mask, buf[2..6]);
    try std.testing.expectEqual(@as(usize, 6), hdr_len);
}

test "encode binary frame" {
    var buf: [frame.MAX_HEADER_SIZE]u8 = undefined;
    const mask = [4]u8{ 0x01, 0x02, 0x03, 0x04 };
    const hdr_len = frame.encodeHeader(&buf, .binary, 10, true, mask);

    try std.testing.expectEqual(@as(u8, 0x82), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x8A), buf[1]);
    try std.testing.expectEqual(@as(usize, 6), hdr_len);
}

test "encode 126-byte payload" {
    var buf: [frame.MAX_HEADER_SIZE]u8 = undefined;
    const mask = [4]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    const hdr_len = frame.encodeHeader(&buf, .binary, 200, true, mask);

    try std.testing.expectEqual(@as(u8, 0x82), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xFE), buf[1]);
    try std.testing.expectEqual(@as(u16, 200), frame.readU16Big(buf[2..4]));
    try std.testing.expectEqual(@as(usize, 8), hdr_len);
}

test "encode 65536-byte payload" {
    var buf: [frame.MAX_HEADER_SIZE]u8 = undefined;
    const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    const hdr_len = frame.encodeHeader(&buf, .binary, 65536, true, mask);

    try std.testing.expectEqual(@as(u8, 0x82), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[1]);
    try std.testing.expectEqual(@as(u64, 65536), frame.readU64Big(buf[2..10]));
    try std.testing.expectEqual(@as(usize, 14), hdr_len);
}

test "decode server frame (no mask)" {
    var buf = [_]u8{
        0x81, // FIN + text
        0x05, // no mask, len=5
        'h',
        'e',
        'l',
        'l',
        'o',
    };
    const f = try frame.decode(&buf);
    try std.testing.expect(f.header.fin);
    try std.testing.expectEqual(frame.Opcode.text, f.header.opcode);
    try std.testing.expect(!f.header.masked);
    try std.testing.expectEqual(@as(u64, 5), f.header.payload_len);
    try std.testing.expectEqualSlices(u8, "hello", f.payload);
}

test "decode 2-byte extended length" {
    var buf: [4 + 200]u8 = undefined;
    buf[0] = 0x82;
    buf[1] = 126;
    frame.writeU16Big(buf[2..4], 200);
    @memset(buf[4..], 0xAB);

    const f = try frame.decode(&buf);
    try std.testing.expectEqual(@as(u64, 200), f.header.payload_len);
    try std.testing.expectEqual(@as(usize, 200), f.payload.len);
    try std.testing.expectEqual(@as(usize, 4), f.header.header_size);
}

test "decode 8-byte extended length" {
    const payload_len: u64 = 70000;
    var buf: [10 + 70000]u8 = undefined;
    buf[0] = 0x82;
    buf[1] = 127;
    frame.writeU64Big(buf[2..10], payload_len);
    @memset(buf[10..], 0xCD);

    const f = try frame.decode(&buf);
    try std.testing.expectEqual(payload_len, f.header.payload_len);
    try std.testing.expectEqual(@as(usize, 70000), f.payload.len);
    try std.testing.expectEqual(@as(usize, 10), f.header.header_size);
}

test "decode with mask" {
    var buf = [_]u8{
        0x81,
        0x85,
        0x37,
        0xfa,
        0x21,
        0x3d,
        0x7f,
        0x9f,
        0x4d,
        0x51,
        0x58,
    };
    const f = try frame.decode(&buf);
    try std.testing.expect(f.header.masked);
    try std.testing.expectEqual([4]u8{ 0x37, 0xfa, 0x21, 0x3d }, f.header.mask_key);

    var payload: [5]u8 = undefined;
    @memcpy(&payload, f.payload);
    frame.applyMask(&payload, f.header.mask_key);
    try std.testing.expectEqualSlices(u8, "Hello", &payload);
}

test "decode truncated header" {
    const buf = [_]u8{0x81};
    try std.testing.expectError(error.TruncatedHeader, frame.decodeHeader(&buf));
}

test "decode truncated payload" {
    const buf = [_]u8{
        0x81,
        0x05,
        'h',
        'e',
    };
    try std.testing.expectError(error.TruncatedPayload, frame.decode(&buf));
}

test "ping frame encode/decode" {
    var buf: [frame.MAX_HEADER_SIZE + 5]u8 = undefined;
    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    const payload = "hello";
    const hdr_len = frame.encodeHeader(&buf, .ping, payload.len, true, mask);
    @memcpy(buf[hdr_len..][0..payload.len], payload);
    frame.applyMask(buf[hdr_len..][0..payload.len], mask);

    const f = try frame.decode(buf[0 .. hdr_len + payload.len]);
    try std.testing.expectEqual(frame.Opcode.ping, f.header.opcode);
    try std.testing.expect(f.header.fin);

    var decoded_payload: [5]u8 = undefined;
    @memcpy(&decoded_payload, f.payload);
    frame.applyMask(&decoded_payload, f.header.mask_key);
    try std.testing.expectEqualSlices(u8, payload, &decoded_payload);
}

test "close frame encode/decode" {
    var buf: [frame.MAX_HEADER_SIZE + 2]u8 = undefined;
    const mask = [4]u8{ 0xAA, 0xBB, 0xCC, 0xDD };

    var close_payload = [2]u8{ 0x03, 0xE8 };
    frame.applyMask(&close_payload, mask);

    const hdr_len = frame.encodeHeader(&buf, .close, 2, true, mask);
    @memcpy(buf[hdr_len..][0..2], &close_payload);

    const f = try frame.decode(buf[0 .. hdr_len + 2]);
    try std.testing.expectEqual(frame.Opcode.close, f.header.opcode);
    try std.testing.expect(f.header.fin);
    try std.testing.expectEqual(@as(u64, 2), f.header.payload_len);

    var status_bytes: [2]u8 = undefined;
    @memcpy(&status_bytes, f.payload);
    frame.applyMask(&status_bytes, f.header.mask_key);
    const status = frame.readU16Big(&status_bytes);
    try std.testing.expectEqual(@as(u16, 1000), status);
}

test "masking roundtrip" {
    const original = "The quick brown fox jumps over the lazy dog";
    var data: [original.len]u8 = undefined;
    @memcpy(&data, original);

    const mask = [4]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    frame.applyMask(&data, mask);

    try std.testing.expect(!std.mem.eql(u8, &data, original));

    frame.applyMask(&data, mask);
    try std.testing.expectEqualSlices(u8, original, &data);
}

test "encode unmasked server frame" {
    var buf: [frame.MAX_HEADER_SIZE]u8 = undefined;
    const hdr_len = frame.encodeHeader(&buf, .text, 5, true, null);

    try std.testing.expectEqual(@as(u8, 0x81), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x05), buf[1]);
    try std.testing.expectEqual(@as(usize, 2), hdr_len);
}

test "applyMaskOffset matches frame.applyMask at offset 0" {
    const original = "test data here!";
    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };

    var a: [original.len]u8 = undefined;
    var b_buf: [original.len]u8 = undefined;
    @memcpy(&a, original);
    @memcpy(&b_buf, original);

    frame.applyMask(&a, mask);
    frame.applyMaskOffset(&b_buf, mask, 0);

    try std.testing.expectEqualSlices(u8, &a, &b_buf);
}

test "decode empty buffer" {
    const buf = [_]u8{};
    try std.testing.expectError(error.TruncatedHeader, frame.decodeHeader(&buf));
}

test "non-fin text frame header" {
    var buf: [frame.MAX_HEADER_SIZE]u8 = undefined;
    const hdr_len = frame.encodeHeader(&buf, .text, 10, false, null);

    try std.testing.expectEqual(@as(u8, 0x01), buf[0]);
    try std.testing.expectEqual(@as(usize, 2), hdr_len);

    const header = try frame.decodeHeader(buf[0..hdr_len]);
    try std.testing.expect(!header.fin);
    try std.testing.expectEqual(frame.Opcode.text, header.opcode);
}
