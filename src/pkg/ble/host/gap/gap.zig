//! GAP — Generic Access Profile
//!
//! BLE advertising, scanning, and connection state machine.
//! Generates HCI commands and processes HCI events.
//!
//! GAP does not directly perform I/O — it generates command packets
//! and processes event packets. The Host coordinator is responsible
//! for the actual transport.
//!
//! ## State Machine
//!
//! ```
//! ┌──────────┐  startAdvertising()  ┌──────────────┐
//! │  Idle    │ ──────────────────→ │  Advertising  │
//! │          │ ←────────────────── │               │
//! │          │  stopAdvertising()   └──────┬───────┘
//! │          │                             │ LE Connection Complete
//! │          │  startScanning()     ┌──────────────┐
//! │          │ ──────────────────→ │  Scanning     │
//! │          │ ←────────────────── │               │
//! │          │  stopScanning()      └──────┬───────┘
//! │          │                             │ connect()
//! │          │                      ┌──────────────┐
//! │          │                      │  Connecting   │
//! │          │                      └──────┬───────┘
//! │          │                             │ LE Connection Complete
//! │          │                      ┌──────────────┐
//! └──────────┘ ←─ disconnect() ──── │  Connected   │
//!                                   └──────────────┘
//! ```

const std = @import("std");
const hci = @import("../hci/hci.zig");
const commands = @import("../hci/commands.zig");
const events = @import("../hci/events.zig");

// ============================================================================
// Types
// ============================================================================

/// GAP state
pub const State = enum {
    idle,
    advertising,
    scanning,
    connecting,
    connected,
};

/// GAP event (delivered to app layer)
pub const GapEvent = union(enum) {
    /// Advertising started successfully
    advertising_started: void,
    /// Advertising stopped (manually or due to connection)
    advertising_stopped: void,
    /// A peer connected
    connected: ConnectionInfo,
    /// A peer disconnected
    disconnected: DisconnectionInfo,
    /// Connection attempt failed
    connection_failed: hci.Status,
    /// Device found during scanning
    device_found: events.AdvReport,
    /// PHY updated (after LE Set PHY)
    phy_updated: events.LePhyUpdateComplete,
    /// Data length changed (after LE Set Data Length)
    data_length_changed: events.LeDataLengthChange,
};

/// Connection info from LE Connection Complete event
pub const ConnectionInfo = struct {
    conn_handle: u16,
    role: Role,
    peer_addr_type: hci.AddrType,
    peer_addr: hci.BdAddr,
    conn_interval: u16,
    conn_latency: u16,
    supervision_timeout: u16,
};

pub const DisconnectionInfo = struct {
    conn_handle: u16,
    reason: u8,
};

pub const Role = enum(u8) {
    central = 0x00,
    peripheral = 0x01,
};

/// Advertising configuration
pub const AdvConfig = struct {
    /// Advertising interval (units of 0.625ms, range: 0x0020-0x4000)
    interval_min: u16 = 0x0800, // 1.28s
    interval_max: u16 = 0x0800,
    /// Advertising type
    adv_type: commands.AdvType = .adv_ind,
    /// Own address type
    own_addr_type: hci.AddrType = .public,
    /// Advertising data (max 31 bytes)
    adv_data: []const u8 = &.{},
    /// Scan response data (max 31 bytes)
    scan_rsp_data: []const u8 = &.{},
    /// Channel map (bit 0=ch37, bit 1=ch38, bit 2=ch39)
    channel_map: u8 = 0x07,
};

/// Scan configuration
pub const ScanConfig = struct {
    /// 0x00 = passive, 0x01 = active
    scan_type: u8 = 0x01,
    /// Scan interval (units of 0.625ms)
    interval: u16 = 0x0010, // 10ms
    /// Scan window (units of 0.625ms)
    window: u16 = 0x0010, // 10ms (= interval → continuous)
    /// Filter duplicates
    filter_duplicates: bool = true,
};

/// Connection parameters
pub const ConnParams = struct {
    /// Connection interval min (units of 1.25ms)
    interval_min: u16 = 0x0006, // 7.5ms
    /// Connection interval max (units of 1.25ms)
    interval_max: u16 = 0x0006, // 7.5ms
    /// Connection latency
    latency: u16 = 0x0000,
    /// Supervision timeout (units of 10ms)
    timeout: u16 = 0x00C8, // 2000ms
};

// ============================================================================
// Command Queue Entry
// ============================================================================

/// A pending HCI command to be sent by the Host
pub const PendingCommand = struct {
    data: [commands.MAX_CMD_LEN]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const PendingCommand) []const u8 {
        return self.data[0..self.len];
    }
};

// ============================================================================
// GAP State Machine
// ============================================================================

/// GAP controller — manages advertising/scanning/connection state.
///
/// Does not perform I/O. Instead:
/// - `startAdvertising()` etc. queue HCI commands into `pending_cmds`
/// - `handleEvent()` processes HCI events and updates state
/// - Host coordinator drains `pending_cmds` and calls `handleEvent()`
pub const Gap = struct {
    const Self = @This();
    const MAX_PENDING = 16;

    state: State = .idle,

    /// Active connection (single connection for now)
    conn_handle: ?u16 = null,
    conn_info: ?ConnectionInfo = null,

    /// Pending HCI commands to be sent
    pending_cmds: [MAX_PENDING]PendingCommand = undefined,
    pending_count: usize = 0,

    /// Pending GAP events to be delivered to app
    pending_events: [MAX_PENDING]GapEvent = undefined,
    event_count: usize = 0,

    pub fn init() Self {
        return .{};
    }

    // ================================================================
    // Peripheral API
    // ================================================================

    /// Start BLE advertising.
    pub fn startAdvertising(self: *Self, config: AdvConfig) !void {
        if (self.state != .idle) return error.InvalidState;

        {
            var buf: [commands.MAX_CMD_LEN]u8 = undefined;
            const cmd = commands.leSetAdvParams(&buf, .{
                .interval_min = config.interval_min,
                .interval_max = config.interval_max,
                .adv_type = config.adv_type,
                .own_addr_type = config.own_addr_type,
                .channel_map = config.channel_map,
            });
            try self.queueCommand(cmd);
        }

        if (config.adv_data.len > 0) {
            var buf: [commands.MAX_CMD_LEN]u8 = undefined;
            const cmd = commands.leSetAdvData(&buf, config.adv_data);
            try self.queueCommand(cmd);
        }

        if (config.scan_rsp_data.len > 0) {
            var buf: [commands.MAX_CMD_LEN]u8 = undefined;
            const cmd = commands.leSetScanRspData(&buf, config.scan_rsp_data);
            try self.queueCommand(cmd);
        }

        {
            var buf: [commands.MAX_CMD_LEN]u8 = undefined;
            const cmd = commands.leSetAdvEnable(&buf, true);
            try self.queueCommand(cmd);
        }

        self.state = .advertising;
    }

    /// Stop BLE advertising.
    pub fn stopAdvertising(self: *Self) !void {
        if (self.state != .advertising) return error.InvalidState;

        var buf: [commands.MAX_CMD_LEN]u8 = undefined;
        const cmd = commands.leSetAdvEnable(&buf, false);
        try self.queueCommand(cmd);
        self.state = .idle;
    }

    // ================================================================
    // Central API
    // ================================================================

    /// Start BLE scanning.
    pub fn startScanning(self: *Self, config: ScanConfig) !void {
        if (self.state != .idle) return error.InvalidState;

        // Set scan parameters
        {
            var buf: [commands.MAX_CMD_LEN]u8 = undefined;
            const cmd = commands.leSetScanParams(&buf, .{
                .scan_type = config.scan_type,
                .interval = config.interval,
                .window = config.window,
            });
            try self.queueCommand(cmd);
        }

        // Enable scanning
        {
            var buf: [commands.MAX_CMD_LEN]u8 = undefined;
            const cmd = commands.leSetScanEnable(&buf, true, config.filter_duplicates);
            try self.queueCommand(cmd);
        }

        self.state = .scanning;
    }

    /// Stop BLE scanning.
    pub fn stopScanning(self: *Self) !void {
        if (self.state != .scanning) return error.InvalidState;

        var buf: [commands.MAX_CMD_LEN]u8 = undefined;
        const cmd = commands.leSetScanEnable(&buf, false, false);
        try self.queueCommand(cmd);
        self.state = .idle;
    }

    /// Initiate a connection to a peer.
    /// Must be in scanning state (auto-stops scanning).
    pub fn connect(
        self: *Self,
        peer_addr: hci.BdAddr,
        peer_addr_type: hci.AddrType,
        params: ConnParams,
    ) !void {
        if (self.state != .scanning and self.state != .idle) return error.InvalidState;

        // Stop scanning first if active
        if (self.state == .scanning) {
            var buf: [commands.MAX_CMD_LEN]u8 = undefined;
            const cmd = commands.leSetScanEnable(&buf, false, false);
            try self.queueCommand(cmd);
        }

        // Create connection
        {
            var buf: [commands.MAX_CMD_LEN]u8 = undefined;
            const cmd = commands.leCreateConnection(&buf, .{
                .peer_addr_type = peer_addr_type,
                .peer_addr = peer_addr,
                .conn_interval_min = params.interval_min,
                .conn_interval_max = params.interval_max,
                .conn_latency = params.latency,
                .supervision_timeout = params.timeout,
            });
            try self.queueCommand(cmd);
        }

        self.state = .connecting;
    }

    // ================================================================
    // Connection Management (both roles)
    // ================================================================

    /// Disconnect an active connection.
    pub fn disconnect(self: *Self, conn_handle: u16, reason: u8) !void {
        if (self.state != .connected) return error.InvalidState;

        var buf: [commands.MAX_CMD_LEN]u8 = undefined;
        const cmd = commands.disconnect(&buf, conn_handle, reason);
        try self.queueCommand(cmd);
    }

    /// Request Data Length Extension (DLE).
    /// Must be connected. tx_octets max 251, tx_time max 2120.
    pub fn requestDataLength(self: *Self, conn_handle: u16, tx_octets: u16, tx_time: u16) !void {
        if (self.state != .connected) return error.InvalidState;

        var buf: [commands.MAX_CMD_LEN]u8 = undefined;
        const cmd = commands.leSetDataLength(&buf, conn_handle, tx_octets, tx_time);
        try self.queueCommand(cmd);
    }

    /// Request PHY update (e.g., 1M → 2M).
    /// tx_phys/rx_phys: bitmask — bit 0 = 1M, bit 1 = 2M, bit 2 = Coded.
    pub fn requestPhyUpdate(self: *Self, conn_handle: u16, tx_phys: u8, rx_phys: u8) !void {
        if (self.state != .connected) return error.InvalidState;

        var buf: [commands.MAX_CMD_LEN]u8 = undefined;
        const cmd = commands.leSetPhy(&buf, conn_handle, 0x00, tx_phys, rx_phys, 0x0000);
        try self.queueCommand(cmd);
    }

    // ================================================================
    // HCI Event Processing
    // ================================================================

    /// Process an HCI event. Updates GAP state and generates GAP events.
    pub fn handleEvent(self: *Self, event: events.Event) void {
        switch (event) {
            .command_complete => |cc| self.handleCommandComplete(cc),
            .command_status => |cs| self.handleCommandStatus(cs),
            .disconnection_complete => |dc| self.handleDisconnection(dc),
            .le_connection_complete => |lc| self.handleConnectionComplete(lc),
            .le_advertising_report => |ar| self.handleAdvertisingReport(ar),
            .le_data_length_change => |dl| self.pushEvent(.{ .data_length_changed = dl }),
            .le_phy_update_complete => |pu| self.pushEvent(.{ .phy_updated = pu }),
            else => {},
        }
    }

    fn handleCommandComplete(self: *Self, cc: events.CommandComplete) void {
        _ = self;
        if (!cc.status.isSuccess()) {
            _ = .{ cc.opcode, @intFromEnum(cc.status) };
        }
    }

    fn handleCommandStatus(self: *Self, cs: events.CommandStatus) void {
        if (!cs.status.isSuccess()) {
            if (cs.opcode == commands.LE_CREATE_CONNECTION) {
                self.state = .idle;
                self.pushEvent(.{ .connection_failed = cs.status });
            }
        }
    }

    fn handleConnectionComplete(self: *Self, lc: events.LeConnectionComplete) void {
        if (!lc.status.isSuccess()) {
            if (self.state == .connecting or self.state == .advertising) {
                self.state = .idle;
                self.pushEvent(.{ .connection_failed = lc.status });
            }
            return;
        }

        const info = ConnectionInfo{
            .conn_handle = lc.conn_handle,
            .role = @enumFromInt(lc.role),
            .peer_addr_type = lc.peer_addr_type,
            .peer_addr = lc.peer_addr,
            .conn_interval = lc.conn_interval,
            .conn_latency = lc.conn_latency,
            .supervision_timeout = lc.supervision_timeout,
        };

        self.conn_handle = lc.conn_handle;
        self.conn_info = info;

        if (self.state == .advertising) {
            self.pushEvent(.{ .advertising_stopped = {} });
        }

        self.state = .connected;
        self.pushEvent(.{ .connected = info });
    }

    fn handleAdvertisingReport(self: *Self, ar: events.LeAdvertisingReport) void {
        if (self.state != .scanning) return;

        // Parse each report in the batch
        var offset: usize = 0;
        var remaining = ar.num_reports;
        while (remaining > 0 and offset < ar.data.len) : (remaining -= 1) {
            if (events.parseAdvReport(ar.data[offset..])) |report| {
                self.pushEvent(.{ .device_found = report });
                // Advance past this report: 1+1+6+1+data_len+1 = 10+data_len
                offset += 10 + report.data.len;
            } else {
                break;
            }
        }
    }

    fn handleDisconnection(self: *Self, dc: events.DisconnectionComplete) void {
        if (!dc.status.isSuccess()) return;

        if (self.conn_handle) |handle| {
            if (handle == dc.conn_handle) {
                self.conn_handle = null;
                self.conn_info = null;
                self.state = .idle;
                self.pushEvent(.{ .disconnected = .{
                    .conn_handle = dc.conn_handle,
                    .reason = dc.reason,
                } });
            }
        }
    }

    // ================================================================
    // Event / Command Queue
    // ================================================================

    pub fn pollEvent(self: *Self) ?GapEvent {
        if (self.event_count == 0) return null;
        const event = self.pending_events[0];
        for (0..self.event_count - 1) |i| {
            self.pending_events[i] = self.pending_events[i + 1];
        }
        self.event_count -= 1;
        return event;
    }

    /// Get the next pending HCI command.
    /// Returns a PendingCommand (value copy, safe to use after next call).
    pub fn nextCommand(self: *Self) ?PendingCommand {
        if (self.pending_count == 0) return null;
        const cmd = self.pending_cmds[0];
        for (0..self.pending_count - 1) |i| {
            self.pending_cmds[i] = self.pending_cmds[i + 1];
        }
        self.pending_count -= 1;
        return cmd;
    }

    fn pushEvent(self: *Self, event: GapEvent) void {
        if (self.event_count >= MAX_PENDING) return;
        self.pending_events[self.event_count] = event;
        self.event_count += 1;
    }

    fn queueCommand(self: *Self, cmd: []const u8) !void {
        if (self.pending_count >= MAX_PENDING) return error.CommandQueueFull;
        var entry = PendingCommand{};
        @memcpy(entry.data[0..cmd.len], cmd);
        entry.len = cmd.len;
        self.pending_cmds[self.pending_count] = entry;
        self.pending_count += 1;
    }
};
