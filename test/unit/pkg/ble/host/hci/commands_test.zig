const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const commands = embed.pkg.ble.host.hci.commands;

test "opcode construction" {
    // HCI_Reset = OGF 0x03, OCF 0x003 = 0x0C03
    try std.testing.expectEqual(@as(u16, 0x0C03), commands.RESET);
    // LE_Set_Adv_Enable = OGF 0x08, OCF 0x00A = 0x200A
    try std.testing.expectEqual(@as(u16, 0x200A), commands.LE_SET_ADV_ENABLE);
}

test "encode HCI Reset" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.reset(&buf);
    try std.testing.expectEqual(@as(usize, 4), pkt.len);
    try std.testing.expectEqual(@as(u8, 0x01), pkt[0]); // command indicator
    try std.testing.expectEqual(@as(u8, 0x03), pkt[1]); // commands.opcode lo
    try std.testing.expectEqual(@as(u8, 0x0C), pkt[2]); // commands.opcode hi
    try std.testing.expectEqual(@as(u8, 0x00), pkt[3]); // param len
}

test "encode LE Set Adv Enable" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leSetAdvEnable(&buf, true);
    try std.testing.expectEqual(@as(usize, 5), pkt.len);
    try std.testing.expectEqual(@as(u8, 0x01), pkt[0]); // command
    try std.testing.expectEqual(@as(u8, 0x0A), pkt[1]); // commands.opcode lo
    try std.testing.expectEqual(@as(u8, 0x20), pkt[2]); // commands.opcode hi
    try std.testing.expectEqual(@as(u8, 0x01), pkt[3]); // param len
    try std.testing.expectEqual(@as(u8, 0x01), pkt[4]); // enable=true
}

test "encode LE Set Adv Data" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    // AD: Flags (0x02, 0x01, 0x06) + Complete Local Name "Zig"
    const ad_data = [_]u8{
        0x02, 0x01, 0x06, // Flags: LE General Discoverable + BR/EDR Not Supported
        0x04, 0x09, 'Z', 'i', 'g', // Complete Local Name: "Zig"
    };
    const pkt = commands.leSetAdvData(&buf, &ad_data);
    try std.testing.expectEqual(@as(usize, 4 + 32), pkt.len); // header + 32 bytes (padded)
    try std.testing.expectEqual(@as(u8, 8), pkt[4]); // data length
    try std.testing.expectEqual(@as(u8, 0x02), pkt[5]); // first AD byte
}

test "new opcodes" {
    try std.testing.expectEqual(@as(u16, 0x200B), commands.LE_SET_SCAN_PARAMS);
    try std.testing.expectEqual(@as(u16, 0x200D), commands.LE_CREATE_CONNECTION);
    try std.testing.expectEqual(@as(u16, 0x2022), commands.LE_SET_DATA_LENGTH);
    try std.testing.expectEqual(@as(u16, 0x2030), commands.LE_READ_PHY);
    try std.testing.expectEqual(@as(u16, 0x2031), commands.LE_SET_DEFAULT_PHY);
    try std.testing.expectEqual(@as(u16, 0x2032), commands.LE_SET_PHY);
}

test "encode LE Set Scan Parameters" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leSetScanParams(&buf, .{});
    try std.testing.expectEqual(@as(usize, 4 + 7), pkt.len);
    try std.testing.expectEqual(@as(u8, 0x0B), pkt[1]); // commands.opcode lo
    try std.testing.expectEqual(@as(u8, 0x20), pkt[2]); // commands.opcode hi
    try std.testing.expectEqual(@as(u8, 7), pkt[3]); // param len
    try std.testing.expectEqual(@as(u8, 0x01), pkt[4]); // active scan
}

test "encode LE Create Connection" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leCreateConnection(&buf, .{
        .peer_addr = .{ 0x50, 0x5C, 0x11, 0xE0, 0x88, 0x98 },
        .conn_interval_min = 0x0006,
        .conn_interval_max = 0x0006,
    });
    try std.testing.expectEqual(@as(usize, 4 + 25), pkt.len);
    try std.testing.expectEqual(@as(u8, 0x0D), pkt[1]); // commands.opcode lo
    try std.testing.expectEqual(@as(u8, 0x20), pkt[2]); // commands.opcode hi
    try std.testing.expectEqual(@as(u8, 25), pkt[3]); // param len
    // Peer addr at offset 4+6=10
    try std.testing.expectEqual(@as(u8, 0x50), pkt[10]);
}

test "encode LE Set Data Length" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leSetDataLength(&buf, 0x0040, 251, 2120);
    try std.testing.expectEqual(@as(usize, 4 + 6), pkt.len);
    try std.testing.expectEqual(@as(u8, 0x22), pkt[1]); // commands.opcode lo
    try std.testing.expectEqual(@as(u8, 0x20), pkt[2]); // commands.opcode hi
    // conn_handle
    try std.testing.expectEqual(@as(u8, 0x40), pkt[4]);
    try std.testing.expectEqual(@as(u8, 0x00), pkt[5]);
    // tx_octets = 251 = 0x00FB
    try std.testing.expectEqual(@as(u8, 0xFB), pkt[6]);
    try std.testing.expectEqual(@as(u8, 0x00), pkt[7]);
}

test "encode LE Set PHY for 2M" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    // Request 2M PHY for both TX and RX
    const pkt = commands.leSetPhy(&buf, 0x0040, 0x00, 0x02, 0x02, 0x0000);
    try std.testing.expectEqual(@as(usize, 4 + 7), pkt.len);
    try std.testing.expectEqual(@as(u8, 0x32), pkt[1]); // commands.opcode lo
    try std.testing.expectEqual(@as(u8, 0x20), pkt[2]); // commands.opcode hi
    try std.testing.expectEqual(@as(u8, 0x02), pkt[7]); // tx_phys = 2M
    try std.testing.expectEqual(@as(u8, 0x02), pkt[8]); // rx_phys = 2M
}
