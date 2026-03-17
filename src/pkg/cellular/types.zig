//! Shared types for the cellular package.
//! No logic, no dependencies. Used by io/, at/, modem/, and cellular.zig.
//! See plan.md §5.1 and cellular_dev.html for full specification.

// -----------------------------------------------------------------------------
// Named constants (avoid magic numbers; Zig has no C-style macros, use const)
// -----------------------------------------------------------------------------

/// Standard UART baud rates in Hz. Use for initial link and CMUX; modems often support AT+IPR to switch.
pub const BaudRate = struct {
    pub const b9600 = 9600;
    pub const b19200 = 19200;
    pub const b38400 = 38400;
    pub const b57600 = 57600;
    pub const b115200 = 115200;
    pub const b230400 = 230400;
    pub const b460800 = 460800;
    /// Common CMUX high-speed rate (e.g. Quectel EC25/EC21 support 921600 via AT+IPR).
    pub const b921600 = 921600;
};

/// Default AT command response timeout in ms. Used by AtEngine and ModemConfig.
pub const default_at_timeout_ms: u32 = 5000;

/// Fixed buffer lengths for modem/SIM identity strings (industry-standard sizes).
pub const BufferLen = struct {
    /// IMEI length in digits (3GPP TS 23.003).
    pub const imei: comptime_int = 15;
    /// IMSI length in digits (3GPP TS 23.003, max 15).
    pub const imsi: comptime_int = 15;
    /// ICCID length in digits (ITU-T E.118, typically 19–20).
    pub const iccid: comptime_int = 20;
    /// Modem model and firmware version string buffer size.
    pub const model: comptime_int = 32;
    pub const firmware: comptime_int = 32;
};

// -----------------------------------------------------------------------------
// Enums and structs
// -----------------------------------------------------------------------------

/// Modem lifecycle and data phase. Drives the Cellular state machine.
pub const CellularPhase = enum {
    off,
    starting,
    ready,
    sim_ready,
    registered,
    dialing,
    connected,
    @"error",
};

/// SIM card status from AT+CPIN? and related.
pub const SimStatus = enum {
    not_inserted,
    pin_required,
    puk_required,
    ready,
    @"error",
};

/// Radio Access Technology (RAT): the cellular air-interface in use (e.g. GSM, LTE).
/// Reported by the modem (e.g. AT+COPS?, AT+CEREG?); distinct from WiFi or other network types.
pub const RAT = enum {
    none,
    gsm,
    gprs,
    edge,
    umts,
    hsdpa,
    lte,
};

/// Cellular network registration status (CREG/CGREG/CEREG): home, roaming, searching, denied, etc.
pub const CellularRegStatus = enum {
    not_registered,
    registered_home,
    searching,
    denied,
    registered_roaming,
    unknown,
};

/// Voice call state (Phase 2): idle, incoming, dialing, alerting, active.
pub const VoiceCallState = enum {
    idle,
    incoming,
    dialing,
    alerting,
    active,
};

/// Cellular signal quality: RSSI (and optionally BER, RSRP, RSRQ for LTE). Aligns with Zephyr cellular_signal naming.
pub const CellularSignalInfo = struct {
    rssi: i8,
    ber: ?u8 = null,
    rsrp: ?i16 = null,
    rsrq: ?i8 = null,
};

/// Module identity: IMEI, model, firmware. Length fields indicate valid bytes in the fixed buffers.
pub const ModemInfo = struct {
    imei: [BufferLen.imei]u8 = [_]u8{0} ** BufferLen.imei,
    imei_len: u8 = 0,
    model: [BufferLen.model]u8 = [_]u8{0} ** BufferLen.model,
    model_len: u8 = 0,
    firmware: [BufferLen.firmware]u8 = [_]u8{0} ** BufferLen.firmware,
    firmware_len: u8 = 0,

    /// Returns the IMEI slice (imei[0..imei_len]).
    pub fn getImei(self: *const ModemInfo) []const u8 {
        return self.imei[0..self.imei_len];
    }

    /// Returns the model string slice.
    pub fn getModel(self: *const ModemInfo) []const u8 {
        return self.model[0..self.model_len];
    }

    /// Returns the firmware version slice.
    pub fn getFirmware(self: *const ModemInfo) []const u8 {
        return self.firmware[0..self.firmware_len];
    }
};

/// SIM identity and status.
pub const SimInfo = struct {
    status: SimStatus = .not_inserted,
    imsi: [BufferLen.imsi]u8 = [_]u8{0} ** BufferLen.imsi,
    imsi_len: u8 = 0,
    iccid: [BufferLen.iccid]u8 = [_]u8{0} ** BufferLen.iccid,
    iccid_len: u8 = 0,

    /// Returns the IMSI slice.
    pub fn getImsi(self: *const SimInfo) []const u8 {
        return self.imsi[0..self.imsi_len];
    }

    /// Returns the ICCID slice.
    pub fn getIccid(self: *const SimInfo) []const u8 {
        return self.iccid[0..self.iccid_len];
    }
};

/// Unified modem error reason. Only meaningful when phase == .error; cleared on retry.
pub const ModemError = enum {
    at_timeout,
    at_fatal,
    sim_not_inserted,
    sim_pin_required,
    sim_error,
    cmux_failed,
    registration_denied,
    registration_failed,
    ppp_failed,
    config_failed,
};

/// Full modem state held by Cellular. Defaults represent power-off.
pub const ModemState = struct {
    phase: CellularPhase = .off,
    sim: SimStatus = .not_inserted,
    registration: CellularRegStatus = .not_registered,
    network_type: RAT = .none,
    signal: ?CellularSignalInfo = null,
    modem_info: ?ModemInfo = null,
    sim_info: ?SimInfo = null,
    error_reason: ?ModemError = null,
    at_timeout_count: u8 = 0,
};

/// Internal events dispatched by the driver layer; reducer maps these to state transitions.
pub const ModemEvent = union(enum) {
    power_on: void,
    power_off: void,
    at_ready: void,
    at_timeout: void,
    sim_ready: void,
    sim_error: SimStatus,
    sim_removed: void,
    pin_required: void,
    registered: CellularRegStatus,
    registration_failed: CellularRegStatus,
    dial_start: void,
    dial_connected: void,
    dial_failed: void,
    ip_obtained: void,
    ip_lost: void,
    signal_updated: CellularSignalInfo,
    retry: void,
    stop: void,
};

/// APN and credentials for PPP/dial (Phase 1: pass-through; Phase 2: apn.zig may resolve).
pub const APNConfig = struct {
    apn: []const u8,
    username: []const u8 = "",
    password: []const u8 = "",
};

/// Role of a CMUX virtual channel: AT commands or PPP data.
pub const CmuxChannelRole = enum { at, ppp };

/// Single CMUX channel: DLCI and role. User-configurable in single-channel mode.
pub const CmuxChannelConfig = struct {
    dlci: u8,
    role: CmuxChannelRole,
};

/// Modem/CMUX/AT engine configuration. Defaults are for single-channel with DLCI 1=PPP, 2=AT.
pub const ModemConfig = struct {
    cmux_channels: []const CmuxChannelConfig = &.{
        .{ .dlci = 1, .role = .ppp },
        .{ .dlci = 2, .role = .at },
    },
    /// CMUX high-speed baud (Hz). Many modems support AT+IPR=921600 for lower latency on single UART.
    cmux_baud_rate: u32 = BaudRate.b921600,
    at_timeout_ms: u32 = default_at_timeout_ms,
    max_urc_handlers: u8 = 16,
    context_id: u8 = 1,
};

/// Payload pushed to the Bus via EventInjector(.cellular). Matches InputSpec.cellular.
pub const CellularPayload = union(enum) {
    phase_changed: struct { from: CellularPhase, to: CellularPhase },
    signal_updated: CellularSignalInfo,
    sim_status_changed: SimStatus,
    registration_changed: CellularRegStatus,
    @"error": ModemError,
};
