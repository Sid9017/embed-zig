//! HCI Event Decoding
//!
//! Decode HCI events received from the controller.
//! Pure data parsing — no I/O, no state.
//!
//! ## Event Packet Format (BT Core Spec Vol 4, Part E, Section 7.7)
//!
//! ```
//! [0x04][Event_Code][Param_Len][Parameters...]
//! ```

const std = @import("std");
const hci = @import("hci.zig");

// ============================================================================
// Event Codes
// ============================================================================

pub const EventCode = enum(u8) {
    /// Disconnection Complete
    disconnection_complete = 0x05,
    /// Command Complete
    command_complete = 0x0E,
    /// Command Status
    command_status = 0x0F,
    /// Hardware Error
    hardware_error = 0x10,
    /// Number of Completed Packets
    num_completed_packets = 0x13,
    /// LE Meta Event (contains sub-event code)
    le_meta = 0x3E,
    _,
};

/// LE Sub-event codes (inside LE Meta Event)
pub const LeSubevent = enum(u8) {
    /// LE Connection Complete
    connection_complete = 0x01,
    /// LE Advertising Report
    advertising_report = 0x02,
    /// LE Connection Update Complete
    connection_update_complete = 0x03,
    /// LE Read Remote Features Complete
    read_remote_features_complete = 0x04,
    /// LE Long Term Key Request
    long_term_key_request = 0x05,
    /// LE Data Length Change
    data_length_change = 0x07,
    /// LE Enhanced Connection Complete (v2)
    enhanced_connection_complete = 0x0A,
    /// LE PHY Update Complete
    phy_update_complete = 0x0C,
    _,
};

// ============================================================================
// Decoded Event Types
// ============================================================================

/// Decoded HCI event
pub const Event = union(enum) {
    /// Command Complete: controller finished processing a command
    command_complete: CommandComplete,
    /// Command Status: controller acknowledged a command
    command_status: CommandStatus,
    /// Disconnection Complete
    disconnection_complete: DisconnectionComplete,
    /// Number of Completed Packets (flow control)
    num_completed_packets: NumCompletedPackets,
    /// LE Connection Complete
    le_connection_complete: LeConnectionComplete,
    /// LE Advertising Report
    le_advertising_report: LeAdvertisingReport,
    /// LE Connection Update Complete
    le_connection_update_complete: LeConnectionUpdateComplete,
    /// LE Data Length Change
    le_data_length_change: LeDataLengthChange,
    /// LE PHY Update Complete
    le_phy_update_complete: LePhyUpdateComplete,
    /// Unknown or unsupported event
    unknown: UnknownEvent,
};

pub const CommandComplete = struct {
    num_cmd_packets: u8,
    opcode: u16,
    status: hci.Status,
    /// Return parameters (after status byte)
    return_params: []const u8,
};

pub const CommandStatus = struct {
    status: hci.Status,
    num_cmd_packets: u8,
    opcode: u16,
};

pub const DisconnectionComplete = struct {
    status: hci.Status,
    conn_handle: u16,
    reason: u8,
};

pub const NumCompletedPackets = struct {
    num_handles: u8,
    /// Raw parameter data: [handle_lo, handle_hi, count_lo, count_hi] * num_handles
    data: []const u8,
};

pub const LeConnectionComplete = struct {
    status: hci.Status,
    conn_handle: u16,
    role: u8,
    peer_addr_type: hci.AddrType,
    peer_addr: hci.BdAddr,
    conn_interval: u16,
    conn_latency: u16,
    supervision_timeout: u16,
};

pub const LeAdvertisingReport = struct {
    num_reports: u8,
    /// Raw report data (variable length, parse with parseAdvReport)
    data: []const u8,
};

/// Parsed single advertising report
pub const AdvReport = struct {
    /// Event type: 0=ADV_IND, 1=ADV_DIRECT_IND, 2=ADV_SCAN_IND, 3=ADV_NONCONN_IND, 4=SCAN_RSP
    event_type: u8,
    /// Advertiser address type
    addr_type: hci.AddrType,
    /// Advertiser address
    addr: hci.BdAddr,
    /// AD structures data
    data: []const u8,
    /// RSSI in dBm (127 = not available)
    rssi: i8,
};

/// Parse the first advertising report from raw LE Advertising Report data.
///
/// Input: raw data after num_reports byte. Format per report:
/// [event_type(1)][addr_type(1)][addr(6)][data_len(1)][data(N)][rssi(1)]
pub fn parseAdvReport(raw: []const u8) ?AdvReport {
    if (raw.len < 10) return null; // minimum: 1+1+6+1+0+1 = 10
    const event_type = raw[0];
    const addr_type: hci.AddrType = @enumFromInt(raw[1]);
    const addr: hci.BdAddr = raw[2..8].*;
    const data_len: usize = raw[8];
    if (raw.len < 9 + data_len + 1) return null;
    const data = raw[9..][0..data_len];
    const rssi: i8 = @bitCast(raw[9 + data_len]);
    return .{
        .event_type = event_type,
        .addr_type = addr_type,
        .addr = addr,
        .data = data,
        .rssi = rssi,
    };
}

pub const LeConnectionUpdateComplete = struct {
    status: hci.Status,
    conn_handle: u16,
    conn_interval: u16,
    conn_latency: u16,
    supervision_timeout: u16,
};

pub const LeDataLengthChange = struct {
    conn_handle: u16,
    max_tx_octets: u16,
    max_tx_time: u16,
    max_rx_octets: u16,
    max_rx_time: u16,
};

pub const LePhyUpdateComplete = struct {
    status: hci.Status,
    conn_handle: u16,
    /// TX PHY: 1=1M, 2=2M, 3=Coded
    tx_phy: u8,
    /// RX PHY: 1=1M, 2=2M, 3=Coded
    rx_phy: u8,
};

pub const UnknownEvent = struct {
    event_code: u8,
    params: []const u8,
};

// ============================================================================
// Decoding
// ============================================================================

/// Decode an HCI event from raw bytes.
///
/// Input `data` should start with the event code (byte after 0x04 indicator).
/// That is: data = [Event_Code][Param_Len][Parameters...]
///
/// Returns null if the data is too short to parse.
pub fn decode(data: []const u8) ?Event {
    if (data.len < 2) return null;

    const event_code: EventCode = @enumFromInt(data[0]);
    const param_len = data[1];

    if (data.len < @as(usize, 2) + param_len) return null;
    const params = data[2..][0..param_len];

    return switch (event_code) {
        .command_complete => decodeCommandComplete(params),
        .command_status => decodeCommandStatus(params),
        .disconnection_complete => decodeDisconnectionComplete(params),
        .num_completed_packets => decodeNumCompletedPackets(params),
        .le_meta => decodeLeMetaEvent(params),
        else => .{ .unknown = .{
            .event_code = data[0],
            .params = params,
        } },
    };
}

pub fn decodeCommandComplete(params: []const u8) ?Event {
    if (params.len < 4) return null;
    return .{ .command_complete = .{
        .num_cmd_packets = params[0],
        .opcode = std.mem.readInt(u16, params[1..3], .little),
        .status = @enumFromInt(params[3]),
        .return_params = if (params.len > 4) params[4..] else &.{},
    } };
}

pub fn decodeCommandStatus(params: []const u8) ?Event {
    if (params.len < 4) return null;
    return .{ .command_status = .{
        .status = @enumFromInt(params[0]),
        .num_cmd_packets = params[1],
        .opcode = std.mem.readInt(u16, params[2..4], .little),
    } };
}

pub fn decodeDisconnectionComplete(params: []const u8) ?Event {
    if (params.len < 4) return null;
    return .{ .disconnection_complete = .{
        .status = @enumFromInt(params[0]),
        .conn_handle = std.mem.readInt(u16, params[1..3], .little) & 0x0FFF,
        .reason = params[3],
    } };
}

pub fn decodeNumCompletedPackets(params: []const u8) ?Event {
    if (params.len < 1) return null;
    return .{ .num_completed_packets = .{
        .num_handles = params[0],
        .data = if (params.len > 1) params[1..] else &.{},
    } };
}

pub fn decodeLeMetaEvent(params: []const u8) ?Event {
    if (params.len < 1) return null;

    const sub: LeSubevent = @enumFromInt(params[0]);
    const sub_params = if (params.len > 1) params[1..] else &[_]u8{};

    return switch (sub) {
        .connection_complete => decodeLeConnectionComplete(sub_params),
        .advertising_report => .{ .le_advertising_report = .{
            .num_reports = if (sub_params.len > 0) sub_params[0] else 0,
            .data = if (sub_params.len > 1) sub_params[1..] else &.{},
        } },
        .connection_update_complete => decodeLeConnectionUpdateComplete(sub_params),
        .data_length_change => decodeLeDataLengthChange(sub_params),
        .phy_update_complete => decodeLePhyUpdateComplete(sub_params),
        else => .{ .unknown = .{
            .event_code = @intFromEnum(EventCode.le_meta),
            .params = params,
        } },
    };
}

pub fn decodeLeConnectionComplete(params: []const u8) ?Event {
    if (params.len < 18) return null;
    return .{ .le_connection_complete = .{
        .status = @enumFromInt(params[0]),
        .conn_handle = std.mem.readInt(u16, params[1..3], .little) & 0x0FFF,
        .role = params[3],
        .peer_addr_type = @enumFromInt(params[4]),
        .peer_addr = params[5..11].*,
        .conn_interval = std.mem.readInt(u16, params[11..13], .little),
        .conn_latency = std.mem.readInt(u16, params[13..15], .little),
        .supervision_timeout = std.mem.readInt(u16, params[15..17], .little),
    } };
}

pub fn decodeLeConnectionUpdateComplete(params: []const u8) ?Event {
    if (params.len < 9) return null;
    return .{ .le_connection_update_complete = .{
        .status = @enumFromInt(params[0]),
        .conn_handle = std.mem.readInt(u16, params[1..3], .little) & 0x0FFF,
        .conn_interval = std.mem.readInt(u16, params[3..5], .little),
        .conn_latency = std.mem.readInt(u16, params[5..7], .little),
        .supervision_timeout = std.mem.readInt(u16, params[7..9], .little),
    } };
}

pub fn decodeLeDataLengthChange(params: []const u8) ?Event {
    if (params.len < 10) return null;
    return .{ .le_data_length_change = .{
        .conn_handle = std.mem.readInt(u16, params[0..2], .little) & 0x0FFF,
        .max_tx_octets = std.mem.readInt(u16, params[2..4], .little),
        .max_tx_time = std.mem.readInt(u16, params[4..6], .little),
        .max_rx_octets = std.mem.readInt(u16, params[6..8], .little),
        .max_rx_time = std.mem.readInt(u16, params[8..10], .little),
    } };
}

pub fn decodeLePhyUpdateComplete(params: []const u8) ?Event {
    if (params.len < 5) return null;
    return .{ .le_phy_update_complete = .{
        .status = @enumFromInt(params[0]),
        .conn_handle = std.mem.readInt(u16, params[1..3], .little) & 0x0FFF,
        .tx_phy = params[3],
        .rx_phy = params[4],
    } };
}
