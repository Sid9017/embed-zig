const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const events = embed.pkg.ble.host.hci.events;
const hci = embed.pkg.ble.host.hci;

test "decode Command Complete for HCI_Reset" {
    // events.Event: Command Complete, Status: Success, OpCode: HCI_Reset
    const raw = [_]u8{
        0x0E, // events.Event Code: Command Complete
        0x04, // Parameter Length
        0x01, // Num_HCI_Command_Packets
        0x03, 0x0C, // OpCode: HCI_Reset (0x0C03)
        0x00, // Status: Success
    };

    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .command_complete => |cc| {
            try std.testing.expectEqual(@as(u8, 0x01), cc.num_cmd_packets);
            try std.testing.expectEqual(@as(u16, 0x0C03), cc.opcode);
            try std.testing.expect(cc.status.isSuccess());
        },
        else => unreachable,
    }
}

test "decode Command Status" {
    const raw = [_]u8{
        0x0F, // events.Event Code: Command Status
        0x04, // Parameter Length
        0x00, // Status: Success (pending)
        0x01, // Num_HCI_Command_Packets
        0x0D, 0x20, // OpCode: LE_Create_Connection (0x200D)
    };

    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .command_status => |cs| {
            try std.testing.expect(cs.status.isSuccess());
            try std.testing.expectEqual(@as(u16, 0x200D), cs.opcode);
        },
        else => unreachable,
    }
}

test "decode LE Connection Complete" {
    const raw = [_]u8{
        0x3E, // events.Event Code: LE Meta
        0x13, // Parameter Length: 19
        0x01, // Sub-event: Connection Complete
        0x00, // Status: Success
        0x40, 0x00, // Connection Handle: 0x0040
        0x01, // Role: Peripheral
        0x01, // Peer Address Type: Random
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, // Peer Address
        0x18, 0x00, // Connection Interval: 30ms
        0x00, 0x00, // Connection Latency: 0
        0xC8, 0x00, // Supervision Timeout: 2000ms
        0x00, // Master Clock Accuracy
    };

    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .le_connection_complete => |lc| {
            try std.testing.expect(lc.status.isSuccess());
            try std.testing.expectEqual(@as(u16, 0x0040), lc.conn_handle);
            try std.testing.expectEqual(@as(u8, 0x01), lc.role);
            try std.testing.expectEqual(hci.hci.AddrType.random, lc.peer_addr_type);
            try std.testing.expectEqual(@as(u16, 0x0018), lc.conn_interval);
        },
        else => unreachable,
    }
}

test "decode LE Data Length Change" {
    const raw = [_]u8{
        0x3E, // LE Meta
        0x0B, // Param len: 11
        0x07, // Sub-event: Data Length Change
        0x40, 0x00, // Connection Handle: 0x0040
        0xFB, 0x00, // Max TX Octets: 251
        0x48, 0x08, // Max TX Time: 2120
        0xFB, 0x00, // Max RX Octets: 251
        0x48, 0x08, // Max RX Time: 2120
    };

    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .le_data_length_change => |dl| {
            try std.testing.expectEqual(@as(u16, 0x0040), dl.conn_handle);
            try std.testing.expectEqual(@as(u16, 251), dl.max_tx_octets);
            try std.testing.expectEqual(@as(u16, 2120), dl.max_tx_time);
            try std.testing.expectEqual(@as(u16, 251), dl.max_rx_octets);
        },
        else => unreachable,
    }
}

test "decode LE PHY Update Complete" {
    const raw = [_]u8{
        0x3E, // LE Meta
        0x06, // Param len: 6
        0x0C, // Sub-event: PHY Update Complete
        0x00, // Status: Success
        0x40, 0x00, // Connection Handle: 0x0040
        0x02, // TX PHY: 2M
        0x02, // RX PHY: 2M
    };

    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .le_phy_update_complete => |pu| {
            try std.testing.expect(pu.status.isSuccess());
            try std.testing.expectEqual(@as(u16, 0x0040), pu.conn_handle);
            try std.testing.expectEqual(@as(u8, 0x02), pu.tx_phy);
            try std.testing.expectEqual(@as(u8, 0x02), pu.rx_phy);
        },
        else => unreachable,
    }
}

test "parse Advertising Report" {
    // Single ADV_IND report from a device advertising "ZigBLE"
    const raw = [_]u8{
        0x00, // events.Event type: ADV_IND
        0x00, // Addr type: Public
        0x50, 0x5C, 0x11, 0xE0, 0x88, 0x98, // Address (little-endian)
        0x0B, // Data length: 11
        // AD structures: Flags + Complete Local Name
        0x02, 0x01, 0x06, // Flags (3 bytes)
        0x07, 0x09, 'Z', 'i', 'g', 'B', 'L', 'E', // Name: "ZigBLE" (8 bytes)
        0xC0, // RSSI: -64 dBm
    };

    const report = events.parseAdvReport(&raw) orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x00), report.event_type);
    try std.testing.expectEqual(hci.hci.AddrType.public, report.addr_type);
    try std.testing.expectEqual(@as(u8, 0x50), report.addr[0]);
    try std.testing.expectEqual(@as(usize, 11), report.data.len);
    try std.testing.expectEqual(@as(i8, -64), report.rssi);
}

test "decode unknown event" {
    const raw = [_]u8{
        0xFF, // Unknown event code
        0x02, // Parameter Length
        0xAA,
        0xBB,
    };

    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .unknown => |u| {
            try std.testing.expectEqual(@as(u8, 0xFF), u.event_code);
            try std.testing.expectEqual(@as(usize, 2), u.params.len);
        },
        else => unreachable,
    }
}
