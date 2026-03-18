const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const att = embed.pkg.ble.host.att.att;

test "UUID operations" {
    const uuid1 = att.UUID.from16(0x2800);
    const uuid2 = att.UUID.from16(0x2800);
    const uuid3 = att.UUID.from16(0x2801);

    try std.testing.expect(uuid1.eql(uuid2));
    try std.testing.expect(!uuid1.eql(uuid3));
    try std.testing.expectEqual(@as(usize, 2), uuid1.byteLen());

    var buf: [16]u8 = undefined;
    const n = uuid1.writeTo(&buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u8, 0x00), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x28), buf[1]);
}

test "encode Error Response" {
    var buf: [att.MAX_PDU_LEN]u8 = undefined;
    const pdu = att.encodeErrorResponse(&buf, .read_request, 0x0010, .attribute_not_found);
    try std.testing.expectEqual(@as(usize, 5), pdu.len);
    try std.testing.expectEqual(@as(u8, 0x01), pdu[0]); // Error Response opcode
    try std.testing.expectEqual(@as(u8, 0x0A), pdu[1]); // Request opcode (Read)
    try std.testing.expectEqual(@as(u8, 0x10), pdu[2]); // Handle lo
    try std.testing.expectEqual(@as(u8, 0x00), pdu[3]); // Handle hi
    try std.testing.expectEqual(@as(u8, 0x0A), pdu[4]); // Error: att.Attribute Not Found
}

test "encode Read Response" {
    var buf: [att.MAX_PDU_LEN]u8 = undefined;
    const pdu = att.encodeReadResponse(&buf, "hello");
    try std.testing.expectEqual(@as(usize, 6), pdu.len);
    try std.testing.expectEqual(@as(u8, 0x0B), pdu[0]); // Read Response opcode
    try std.testing.expectEqualStrings("hello", pdu[1..6]);
}

test "encode Notification" {
    var buf: [att.MAX_PDU_LEN]u8 = undefined;
    const pdu = att.encodeNotification(&buf, 0x0015, "data");
    try std.testing.expectEqual(@as(usize, 7), pdu.len);
    try std.testing.expectEqual(@as(u8, 0x1B), pdu[0]); // Notification opcode
    try std.testing.expectEqual(@as(u16, 0x0015), std.mem.readInt(u16, pdu[1..3], .little));
    try std.testing.expectEqualStrings("data", pdu[3..7]);
}

test "decode Exchange MTU Request" {
    const data = [_]u8{ 0x02, 0xF7, 0x00 }; // MTU=247
    const pdu = att.decodePdu(&data) orelse unreachable;
    switch (pdu) {
        .exchange_mtu_request => |mtu_req| {
            try std.testing.expectEqual(@as(u16, 247), mtu_req.client_mtu);
        },
        else => unreachable,
    }
}

test "decode Read Request" {
    const data = [_]u8{ 0x0A, 0x15, 0x00 }; // handle=0x0015
    const pdu = att.decodePdu(&data) orelse unreachable;
    switch (pdu) {
        .read_request => |rr| {
            try std.testing.expectEqual(@as(u16, 0x0015), rr.handle);
        },
        else => unreachable,
    }
}

test "decode Write Request" {
    const data = [_]u8{ 0x12, 0x15, 0x00, 0xAA, 0xBB };
    const pdu = att.decodePdu(&data) orelse unreachable;
    switch (pdu) {
        .write_request => |wr| {
            try std.testing.expectEqual(@as(u16, 0x0015), wr.handle);
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB }, wr.value);
        },
        else => unreachable,
    }
}

test "decode Read By Group Type Request" {
    const data = [_]u8{ 0x10, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28 }; // att.UUID=0x2800
    const pdu = att.decodePdu(&data) orelse unreachable;
    switch (pdu) {
        .read_by_group_type_request => |req| {
            try std.testing.expectEqual(@as(u16, 0x0001), req.start_handle);
            try std.testing.expectEqual(@as(u16, 0xFFFF), req.end_handle);
            try std.testing.expect(req.uuid.eql(att.UUID.from16(0x2800)));
        },
        else => unreachable,
    }
}

test "Attribute database" {
    var db = att.AttributeDb(16){};

    _ = try db.add(.{
        .handle = 0x0001,
        .att_type = att.UUID.from16(att.GATT_PRIMARY_SERVICE_UUID),
        .value = &.{ 0x0D, 0x18 }, // Heart Rate Service att.UUID
        .permissions = .{ .readable = true },
    });

    _ = try db.add(.{
        .handle = 0x0002,
        .att_type = att.UUID.from16(att.GATT_CHARACTERISTIC_UUID),
        .value = &.{ 0x10, 0x03, 0x00, 0x37, 0x2A }, // props + handle + uuid
        .permissions = .{ .readable = true },
    });

    // Find by handle
    const attr = db.findByHandle(0x0001) orelse unreachable;
    try std.testing.expect(attr.att_type.eql(att.UUID.from16(att.GATT_PRIMARY_SERVICE_UUID)));

    // Find by type in range
    var iter = db.findByType(0x0001, 0xFFFF, att.UUID.from16(att.GATT_PRIMARY_SERVICE_UUID));
    const found = iter.next() orelse unreachable;
    try std.testing.expectEqual(@as(u16, 0x0001), found.handle);
    try std.testing.expect(iter.next() == null);
}

test "CharProps packed layout" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(att.CharProps));

    const rw: att.CharProps = .{ .read = true, .write = true };
    try std.testing.expect(rw.read);
    try std.testing.expect(rw.write);
    try std.testing.expect(!rw.notify);
}
