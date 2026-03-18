const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const gap_mod = embed.pkg.ble.host.gap.gap;

test "GAP start advertising generates commands" {
    var gap = gap_mod.Gap.init();

    try gap.startAdvertising(.{
        .adv_data = &[_]u8{ 0x02, 0x01, 0x06, 0x04, 0x09, 'Z', 'i', 'g' },
    });

    try std.testing.expectEqual(gap_mod.State.advertising, gap.state);
    try std.testing.expectEqual(@as(usize, 3), gap.pending_count);

    const cmd1 = gap.nextCommand() orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x01), cmd1.data[0]);
    _ = gap.nextCommand() orelse unreachable;
    _ = gap.nextCommand() orelse unreachable;
    try std.testing.expect(gap.nextCommand() == null);
}

test "GAP start scanning generates commands" {
    var gap = gap_mod.Gap.init();

    try gap.startScanning(.{});

    try std.testing.expectEqual(gap_mod.State.scanning, gap.state);
    try std.testing.expectEqual(@as(usize, 2), gap.pending_count);

    // First: LE Set Scan Params
    const cmd1 = gap.nextCommand() orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x01), cmd1.data[0]); // command indicator
    try std.testing.expectEqual(@as(u8, 0x0B), cmd1.data[1]); // opcode lo (0x200B)

    // Second: LE Set Scan Enable
    const cmd2 = gap.nextCommand() orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x0C), cmd2.data[1]); // opcode lo (0x200C)
}

test "GAP connect from scanning" {
    var gap = gap_mod.Gap.init();

    try gap.startScanning(.{});
    while (gap.nextCommand()) |_| {} // drain

    try gap.connect(
        .{ 0x50, 0x5C, 0x11, 0xE0, 0x88, 0x98 },
        .public,
        .{},
    );

    try std.testing.expectEqual(gap_mod.State.connecting, gap.state);
    // Should have 2 gap_mod.commands: stop scan + create connection
    try std.testing.expectEqual(@as(usize, 2), gap.pending_count);

    // First: disable scanning
    const cmd1 = gap.nextCommand() orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x0C), cmd1.data[1]); // LE_SET_SCAN_ENABLE

    // Second: create connection
    const cmd2 = gap.nextCommand() orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x0D), cmd2.data[1]); // LE_CREATE_CONNECTION
}

test "GAP handle LE Connection Complete (peripheral)" {
    var gap = gap_mod.Gap.init();

    try gap.startAdvertising(.{});
    while (gap.nextCommand()) |_| {}

    gap.handleEvent(.{ .le_connection_complete = .{
        .status = .success,
        .conn_handle = 0x0040,
        .role = 0x01,
        .peer_addr_type = .random,
        .peer_addr = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 },
        .conn_interval = 0x0006,
        .conn_latency = 0,
        .supervision_timeout = 0x00C8,
    } });

    try std.testing.expectEqual(gap_mod.State.connected, gap.state);
    try std.testing.expectEqual(@as(?u16, 0x0040), gap.conn_handle);

    const evt1 = gap.pollEvent() orelse unreachable;
    try std.testing.expect(std.meta.activeTag(evt1) == .advertising_stopped);

    const evt2 = gap.pollEvent() orelse unreachable;
    switch (evt2) {
        .connected => |info| {
            try std.testing.expectEqual(gap_mod.Role.peripheral, info.role);
            try std.testing.expectEqual(@as(u16, 0x0006), info.conn_interval);
        },
        else => unreachable,
    }
}

test "GAP handle LE Connection Complete (central)" {
    var gap = gap_mod.Gap.init();

    gap.state = .connecting;

    gap.handleEvent(.{
        .le_connection_complete = .{
            .status = .success,
            .conn_handle = 0x0041,
            .role = 0x00, // central
            .peer_addr_type = .public,
            .peer_addr = .{ 0x50, 0x5C, 0x11, 0xE0, 0x88, 0x98 },
            .conn_interval = 0x0006,
            .conn_latency = 0,
            .supervision_timeout = 0x00C8,
        },
    });

    try std.testing.expectEqual(gap_mod.State.connected, gap.state);

    const evt = gap.pollEvent() orelse unreachable;
    switch (evt) {
        .connected => |info| {
            try std.testing.expectEqual(gap_mod.Role.central, info.role);
            try std.testing.expectEqual(@as(u16, 0x0041), info.conn_handle);
        },
        else => unreachable,
    }
}

test "GAP request DLE and PHY" {
    var gap = gap_mod.Gap.init();
    gap.state = .connected;
    gap.conn_handle = 0x0040;

    // Request DLE
    try gap.requestDataLength(0x0040, 251, 2120);
    try std.testing.expectEqual(@as(usize, 1), gap.pending_count);

    const cmd1 = gap.nextCommand() orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x22), cmd1.data[1]); // LE_SET_DATA_LENGTH

    // Request 2M PHY
    try gap.requestPhyUpdate(0x0040, 0x02, 0x02);
    try std.testing.expectEqual(@as(usize, 1), gap.pending_count);

    const cmd2 = gap.nextCommand() orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x32), cmd2.data[1]); // LE_SET_PHY
}

test "GAP handle PHY Update Complete event" {
    var gap = gap_mod.Gap.init();
    gap.state = .connected;

    gap.handleEvent(.{ .le_phy_update_complete = .{
        .status = .success,
        .conn_handle = 0x0040,
        .tx_phy = 0x02,
        .rx_phy = 0x02,
    } });

    const evt = gap.pollEvent() orelse unreachable;
    switch (evt) {
        .phy_updated => |pu| {
            try std.testing.expectEqual(@as(u8, 0x02), pu.tx_phy);
            try std.testing.expectEqual(@as(u8, 0x02), pu.rx_phy);
        },
        else => unreachable,
    }
}

test "GAP handle Data Length Change event" {
    var gap = gap_mod.Gap.init();
    gap.state = .connected;

    gap.handleEvent(.{ .le_data_length_change = .{
        .conn_handle = 0x0040,
        .max_tx_octets = 251,
        .max_tx_time = 2120,
        .max_rx_octets = 251,
        .max_rx_time = 2120,
    } });

    const evt = gap.pollEvent() orelse unreachable;
    switch (evt) {
        .data_length_changed => |dl| {
            try std.testing.expectEqual(@as(u16, 251), dl.max_tx_octets);
            try std.testing.expectEqual(@as(u16, 2120), dl.max_tx_time);
        },
        else => unreachable,
    }
}

test "GAP handle Disconnection Complete" {
    var gap = gap_mod.Gap.init();
    gap.state = .connected;
    gap.conn_handle = 0x0040;

    gap.handleEvent(.{ .disconnection_complete = .{
        .status = .success,
        .conn_handle = 0x0040,
        .reason = 0x13,
    } });

    try std.testing.expectEqual(gap_mod.State.idle, gap.state);
    try std.testing.expect(gap.conn_handle == null);

    const evt = gap.pollEvent() orelse unreachable;
    switch (evt) {
        .disconnected => |info| {
            try std.testing.expectEqual(@as(u8, 0x13), info.reason);
        },
        else => unreachable,
    }
}

test "GAP state validation" {
    var gap = gap_mod.Gap.init();

    try std.testing.expectError(error.InvalidState, gap.stopAdvertising());
    try std.testing.expectError(error.InvalidState, gap.stopScanning());
    try std.testing.expectError(error.InvalidState, gap.disconnect(0, 0x13));

    gap.state = .connected;
    try std.testing.expectError(error.InvalidState, gap.startAdvertising(.{}));
    try std.testing.expectError(error.InvalidState, gap.startScanning(.{}));
}
