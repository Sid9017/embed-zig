const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const l2cap = embed.pkg.ble.host.l2cap.l2cap;
const hci = embed.pkg.ble.host.hci;

test "parse L2CAP header" {
    const data = [_]u8{
        0x03, 0x00, // Length: 3
        0x04, 0x00, // CID: ATT (0x0004)
        0x02, 0x01, 0x00, // payload
    };

    const hdr = l2cap.parseHeader(&data) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 3), hdr.length);
    try std.testing.expectEqual(l2cap.CID_ATT, hdr.cid);
}

test "reassemble single fragment" {
    var reasm = l2cap.Reassembler{};

    // Single ACL packet containing complete L2CAP SDU
    const acl_data = [_]u8{
        0x03, 0x00, // L2CAP length: 3
        0x04, 0x00, // CID: ATT
        0xAA, 0xBB, 0xCC, // payload
    };

    const hdr = hci.acl.AclHeader{
        .conn_handle = 0x0040,
        .pb_flag = .first_auto_flush,
        .bc_flag = .point_to_point,
        .data_len = @intCast(acl_data.len),
    };

    const sdu = reasm.feed(hdr, &acl_data) orelse {
        return error.TestUnexpectedResult;
    };

    try std.testing.expectEqual(@as(u16, 0x0040), sdu.conn_handle);
    try std.testing.expectEqual(l2cap.CID_ATT, sdu.cid);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, sdu.data);
}

test "reassemble two fragments" {
    var reasm = l2cap.Reassembler{};

    // Fragment 1: L2CAP header + partial data
    const frag1 = [_]u8{
        0x04, 0x00, // L2CAP length: 4
        0x04, 0x00, // CID: ATT
        0x01, 0x02, // partial payload
    };

    const hdr1 = hci.acl.AclHeader{
        .conn_handle = 0x0040,
        .pb_flag = .first_auto_flush,
        .bc_flag = .point_to_point,
        .data_len = @intCast(frag1.len),
    };

    // First fragment should not complete
    try std.testing.expect(reasm.feed(hdr1, &frag1) == null);

    // Fragment 2: remaining data
    const frag2 = [_]u8{ 0x03, 0x04 };
    const hdr2 = hci.acl.AclHeader{
        .conn_handle = 0x0040,
        .pb_flag = .continuing,
        .bc_flag = .point_to_point,
        .data_len = @intCast(frag2.len),
    };

    const sdu = reasm.feed(hdr2, &frag2) orelse {
        return error.TestUnexpectedResult;
    };

    try std.testing.expectEqual(l2cap.CID_ATT, sdu.cid);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04 }, sdu.data);
}

test "reassemble three fragments (MTU 512 scenario)" {
    var reasm = l2cap.Reassembler{};

    // Simulate a 512-byte ATT payload = 516 bytes with L2CAP header
    // Fragmented into 3 ACL packets with DLE 251:
    //   Frag 1: 251 bytes (L2CAP header + 247 bytes data) — first
    //   Frag 2: 251 bytes (251 bytes data) — continuing
    //   Frag 3: 14 bytes (remaining data) — continuing

    // Build the full L2CAP SDU: [len=512][CID=0x0004][512 bytes payload]
    var full_sdu: [516]u8 = undefined;
    std.mem.writeInt(u16, full_sdu[0..2], 512, .little); // L2CAP length
    std.mem.writeInt(u16, full_sdu[2..4], l2cap.CID_ATT, .little); // CID
    for (0..512) |i| {
        full_sdu[4 + i] = @truncate(i); // pattern fill
    }

    // Fragment 1: first 251 bytes
    const hdr1 = hci.acl.AclHeader{
        .conn_handle = 0x0040,
        .pb_flag = .first_auto_flush,
        .bc_flag = .point_to_point,
        .data_len = 251,
    };
    try std.testing.expect(reasm.feed(hdr1, full_sdu[0..251]) == null);

    // Fragment 2: next 251 bytes
    const hdr2 = hci.acl.AclHeader{
        .conn_handle = 0x0040,
        .pb_flag = .continuing,
        .bc_flag = .point_to_point,
        .data_len = 251,
    };
    try std.testing.expect(reasm.feed(hdr2, full_sdu[251..502]) == null);

    // Fragment 3: remaining 14 bytes → completes SDU
    const hdr3 = hci.acl.AclHeader{
        .conn_handle = 0x0040,
        .pb_flag = .continuing,
        .bc_flag = .point_to_point,
        .data_len = 14,
    };
    const sdu = reasm.feed(hdr3, full_sdu[502..516]) orelse {
        return error.TestUnexpectedResult;
    };

    try std.testing.expectEqual(@as(u16, 0x0040), sdu.conn_handle);
    try std.testing.expectEqual(l2cap.CID_ATT, sdu.cid);
    try std.testing.expectEqual(@as(usize, 512), sdu.data.len);
    // Verify first and last payload bytes
    try std.testing.expectEqual(@as(u8, 0), sdu.data[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), sdu.data[255]);
}

test "fragment iterator single fragment" {
    var sdu_buf: [hci.acl.LE_MAX_DATA_LEN + l2cap.HEADER_LEN]u8 = undefined;
    const payload_data = [_]u8{ 0x01, 0x02, 0x03 };
    var iter = l2cap.fragmentIterator(&sdu_buf, &payload_data, l2cap.CID_ATT, 0x0040, 27);

    // Should produce exactly one fragment (3 + 4 header = 7 < 27 MTU)
    const frag = iter.next() orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x02), frag[0]); // ACL indicator

    // No more fragments
    try std.testing.expect(iter.next() == null);
}
