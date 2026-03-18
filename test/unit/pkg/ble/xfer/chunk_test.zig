const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const chunk = embed.pkg.ble.xfer.chunk;

test "Header encode/decode roundtrip" {
    const cases = [_]chunk.Header{
        .{ .total = 1, .seq = 1 },
        .{ .total = 100, .seq = 50 },
        .{ .total = 4095, .seq = 4095 },
        .{ .total = 4095, .seq = 1 },
        .{ .total = 256, .seq = 128 },
        .{ .total = 0xABC, .seq = 0x123 },
    };
    for (cases) |h| {
        const encoded = h.encode();
        const decoded = chunk.Header.decode(&encoded);
        try std.testing.expectEqual(h.total, decoded.total);
        try std.testing.expectEqual(h.seq, decoded.seq);
    }
}

test "Header validate" {
    try (chunk.Header{ .total = 1, .seq = 1 }).validate();
    try (chunk.Header{ .total = 4095, .seq = 4095 }).validate();
    try (chunk.Header{ .total = 100, .seq = 100 }).validate();

    try std.testing.expectError(error.InvalidHeader, (chunk.Header{ .total = 0, .seq = 1 }).validate());
    try std.testing.expectError(error.InvalidHeader, (chunk.Header{ .total = 1, .seq = 0 }).validate());
    try std.testing.expectError(error.InvalidHeader, (chunk.Header{ .total = 1, .seq = 2 }).validate());
    try std.testing.expectError(error.InvalidHeader, (chunk.Header{ .total = 4096, .seq = 1 }).validate());
}

test "Control message detection" {
    try std.testing.expect(chunk.isStartMagic(&chunk.start_magic));
    try std.testing.expect(!chunk.isStartMagic(&[_]u8{ 0xFF, 0xFF, 0x00, 0x02 }));
    try std.testing.expect(!chunk.isStartMagic(&[_]u8{ 0xFF, 0xFF }));

    try std.testing.expect(chunk.isAck(&chunk.ack_signal));
    try std.testing.expect(chunk.isAck(&[_]u8{ 0xFF, 0xFF, 0x00 })); // extra bytes ok
    try std.testing.expect(!chunk.isAck(&[_]u8{0xFF})); // too short
}

test "Loss list encode/decode roundtrip" {
    const seqs = [_]u16{ 1, 42, 4095 };
    var buf: [6]u8 = undefined;
    const encoded = chunk.encodeLossList(&seqs, &buf);
    try std.testing.expectEqual(@as(usize, 6), encoded.len);

    var decoded: [3]u16 = undefined;
    const count = chunk.decodeLossList(encoded, &decoded);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(u16, 1), decoded[0]);
    try std.testing.expectEqual(@as(u16, 42), decoded[1]);
    try std.testing.expectEqual(@as(u16, 4095), decoded[2]);
}

test "Loss list truncation" {
    const seqs = [_]u16{ 1, 2, 3 };
    var buf: [4]u8 = undefined; // only room for 2 seqs
    const encoded = chunk.encodeLossList(&seqs, &buf);
    try std.testing.expectEqual(@as(usize, 4), encoded.len);

    var decoded: [2]u16 = undefined;
    const count = chunk.decodeLossList(encoded, &decoded);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u16, 1), decoded[0]);
    try std.testing.expectEqual(@as(u16, 2), decoded[1]);
}

test "Bitmask basic operations" {
    var buf: [2]u8 = undefined;
    chunk.Bitmask.initClear(&buf, 10);

    try std.testing.expect(!chunk.Bitmask.isSet(&buf, 1));
    try std.testing.expect(!chunk.Bitmask.isSet(&buf, 10));

    chunk.Bitmask.set(&buf, 1);
    try std.testing.expect(chunk.Bitmask.isSet(&buf, 1));
    try std.testing.expect(!chunk.Bitmask.isSet(&buf, 2));

    chunk.Bitmask.set(&buf, 10);
    try std.testing.expect(chunk.Bitmask.isSet(&buf, 10));

    chunk.Bitmask.clear(&buf, 1);
    try std.testing.expect(!chunk.Bitmask.isSet(&buf, 1));
    try std.testing.expect(chunk.Bitmask.isSet(&buf, 10));
}

test "Bitmask initAllSet" {
    // 10 chunks → 2 bytes, bits 0-9 set
    var buf: [2]u8 = undefined;
    chunk.Bitmask.initAllSet(&buf, 10);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x03), buf[1]);

    // 8 chunks → 1 byte, all bits set
    var buf2: [1]u8 = undefined;
    chunk.Bitmask.initAllSet(&buf2, 8);
    try std.testing.expectEqual(@as(u8, 0xFF), buf2[0]);

    // 1 chunk → 1 byte, bit 0 only
    var buf3: [1]u8 = undefined;
    chunk.Bitmask.initAllSet(&buf3, 1);
    try std.testing.expectEqual(@as(u8, 0x01), buf3[0]);

    // 16 chunks → 2 bytes, all set
    var buf4: [2]u8 = undefined;
    chunk.Bitmask.initAllSet(&buf4, 16);
    try std.testing.expectEqual(@as(u8, 0xFF), buf4[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf4[1]);
}

test "Bitmask isComplete" {
    var buf: [2]u8 = undefined;
    chunk.Bitmask.initClear(&buf, 10);
    try std.testing.expect(!chunk.Bitmask.isComplete(&buf, 10));

    // Set all 10 bits
    for (1..11) |seq| {
        chunk.Bitmask.set(&buf, @intCast(seq));
    }
    try std.testing.expect(chunk.Bitmask.isComplete(&buf, 10));

    // Clear one
    chunk.Bitmask.clear(&buf, 5);
    try std.testing.expect(!chunk.Bitmask.isComplete(&buf, 10));

    // Edge case: 8 chunks (exact byte boundary)
    var buf2: [1]u8 = undefined;
    chunk.Bitmask.initClear(&buf2, 8);
    for (1..9) |seq| {
        chunk.Bitmask.set(&buf2, @intCast(seq));
    }
    try std.testing.expect(chunk.Bitmask.isComplete(&buf2, 8));
}

test "Bitmask collectMissing" {
    var buf: [2]u8 = undefined;
    chunk.Bitmask.initClear(&buf, 10);

    // Set all except 3, 7
    for (1..11) |seq| {
        if (seq != 3 and seq != 7) {
            chunk.Bitmask.set(&buf, @intCast(seq));
        }
    }

    var missing: [10]u16 = undefined;
    const count = chunk.Bitmask.collectMissing(&buf, 10, &missing);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u16, 3), missing[0]);
    try std.testing.expectEqual(@as(u16, 7), missing[1]);
}

test "Bitmask collectMissing with limited output" {
    var buf: [1]u8 = undefined;
    chunk.Bitmask.initClear(&buf, 5); // all missing

    var missing: [2]u16 = undefined; // only room for 2
    const count = chunk.Bitmask.collectMissing(&buf, 5, &missing);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u16, 1), missing[0]);
    try std.testing.expectEqual(@as(u16, 2), missing[1]);
}

test "dataChunkSize" {
    try std.testing.expectEqual(@as(usize, 241), chunk.dataChunkSize(247));
    try std.testing.expectEqual(@as(usize, 24), chunk.dataChunkSize(30));
    try std.testing.expectEqual(@as(usize, 1), chunk.dataChunkSize(7));
    try std.testing.expectEqual(@as(usize, 1), chunk.dataChunkSize(6)); // at overhead
    try std.testing.expectEqual(@as(usize, 1), chunk.dataChunkSize(1)); // below overhead
}

test "chunksNeeded" {
    // MTU=247, dcs=241
    try std.testing.expectEqual(@as(usize, 5), chunk.chunksNeeded(1000, 247));
    try std.testing.expectEqual(@as(usize, 4), chunk.chunksNeeded(964, 247)); // 4*241=964
    try std.testing.expectEqual(@as(usize, 1), chunk.chunksNeeded(1, 247));
    try std.testing.expectEqual(@as(usize, 0), chunk.chunksNeeded(0, 247));

    // MTU=30, dcs=24
    try std.testing.expectEqual(@as(usize, 3), chunk.chunksNeeded(56, 30)); // ceil(56/24)=3
    try std.testing.expectEqual(@as(usize, 2), chunk.chunksNeeded(48, 30)); // exact
    try std.testing.expectEqual(@as(usize, 2), chunk.chunksNeeded(25, 30)); // just over 1
}
