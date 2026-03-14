//! WiFi HAL wrapper (event-driven).

const std = @import("std");
const hal_marker = @import("marker.zig");

pub const Error = error{
    Busy,
    InvalidConfig,
    AuthFailed,
    Timeout,
    WifiError,
};

pub const IpAddress = [4]u8;
pub const Mac = [6]u8;

pub const State = enum {
    disconnected,
    connecting,
    connected,
    failed,
    ap_running,
};

pub const DisconnectReason = enum {
    user_request,
    auth_failed,
    ap_not_found,
    connection_lost,
    unknown,
};

pub const FailReason = enum {
    timeout,
    auth_failed,
    ap_not_found,
    dhcp_failed,
    unknown,
};

pub const AuthMode = enum {
    open,
    wep,
    wpa_psk,
    wpa2_psk,
    wpa_wpa2_psk,
    wpa3_psk,
    wpa2_wpa3_psk,
    wpa2_enterprise,
    wpa3_enterprise,
};

pub const PhyMode = enum {
    @"11b",
    @"11g",
    @"11n",
    @"11a",
    @"11ac",
    @"11ax",
};

pub const ScanType = enum {
    active,
    passive,
};

pub const ScanDoneInfo = struct {
    success: bool,
};

pub const ConnectConfig = struct {
    ssid: []const u8,
    password: []const u8,
    channel_hint: u8 = 0,
    bssid: ?Mac = null,
    auth_mode: ?AuthMode = null,
    timeout_ms: u32 = 30_000,
};

pub const ScanConfig = struct {
    ssid: ?[]const u8 = null,
    bssid: ?Mac = null,
    channel: u8 = 0,
    show_hidden: bool = false,
    scan_type: ScanType = .active,
};

pub const ApInfo = struct {
    ssid: [32]u8,
    ssid_len: u8,
    bssid: Mac,
    channel: u8,
    rssi: i8,
    auth_mode: AuthMode,

    pub fn getSsid(self: *const ApInfo) []const u8 {
        return self.ssid[0..self.ssid_len];
    }
};

pub const PowerSaveMode = enum {
    none,
    min_modem,
    max_modem,
};

pub const RoamingConfig = struct {
    rm_enabled: bool = false,
    btm_enabled: bool = false,
    ft_enabled: bool = false,
    mbo_enabled: bool = false,
};

pub const ApConfig = struct {
    ssid: []const u8,
    password: []const u8,
    channel: u8 = 1,
    auth_mode: AuthMode = .wpa2_psk,
    max_connections: u8 = 4,
    hidden: bool = false,
    beacon_interval: u16 = 100,
};

pub const StaInfo = struct {
    mac: Mac,
    rssi: i8,
    aid: u16,
};

pub const Protocol = packed struct {
    b: bool = true,
    g: bool = true,
    n: bool = true,
    lr: bool = false,
    _padding: u4 = 0,
};

pub const Bandwidth = enum {
    bw_20,
    bw_40,
};

pub const WifiEvent = union(enum) {
    connected: void,
    disconnected: DisconnectReason,
    connection_failed: FailReason,
    scan_result: ApInfo,
    scan_done: ScanDoneInfo,
    rssi_low: i8,
    ap_sta_connected: StaInfo,
    ap_sta_disconnected: StaInfo,
};

pub const Status = struct {
    state: State,
    ip: ?IpAddress,
    rssi: ?i8,
    ssid: ?[]const u8,
    bssid: ?Mac = null,
    channel: ?u8 = null,
    phy_mode: ?PhyMode = null,
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .wifi;
}

/// Required driver methods:
/// - connect(*Driver, []const u8, []const u8) void
/// - disconnect(*Driver) void
/// - isConnected(*const Driver) bool
/// - pollEvent(*Driver) ?WifiEvent
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };

    comptime {
        _ = @as(*const fn (*BaseDriver, []const u8, []const u8) void, &BaseDriver.connect);
        _ = @as(*const fn (*BaseDriver) void, &BaseDriver.disconnect);
        _ = @as(*const fn (*const BaseDriver) bool, &BaseDriver.isConnected);
        _ = @as(*const fn (*BaseDriver) ?WifiEvent, &BaseDriver.pollEvent);

        _ = @as(*const fn (*BaseDriver, ConnectConfig) void, &BaseDriver.connectWithConfig);
        _ = @as(*const fn (*BaseDriver) void, &BaseDriver.reconnect);
        _ = @as(*const fn (*const BaseDriver) ?i8, &BaseDriver.getRssi);
        _ = @as(*const fn (*const BaseDriver) ?Mac, &BaseDriver.getMac);
        _ = @as(*const fn (*const BaseDriver) ?u8, &BaseDriver.getChannel);
        _ = @as(*const fn (*const BaseDriver) ?[]const u8, &BaseDriver.getSsid);
        _ = @as(*const fn (*const BaseDriver) ?Mac, &BaseDriver.getBssid);
        _ = @as(*const fn (*const BaseDriver) ?PhyMode, &BaseDriver.getPhyMode);

        _ = @as(*const fn (*BaseDriver, ScanConfig) Error!void, &BaseDriver.scanStart);

        _ = @as(*const fn (*BaseDriver, PowerSaveMode) void, &BaseDriver.setPowerSave);
        _ = @as(*const fn (*const BaseDriver) PowerSaveMode, &BaseDriver.getPowerSave);

        _ = @as(*const fn (*BaseDriver, RoamingConfig) void, &BaseDriver.setRoaming);
        _ = @as(*const fn (*BaseDriver, i8) void, &BaseDriver.setRssiThreshold);
        _ = @as(*const fn (*BaseDriver, i8) void, &BaseDriver.setTxPower);
        _ = @as(*const fn (*const BaseDriver) ?i8, &BaseDriver.getTxPower);

        _ = @as(*const fn (*BaseDriver, ApConfig) Error!void, &BaseDriver.startAp);
        _ = @as(*const fn (*BaseDriver) void, &BaseDriver.stopAp);
        _ = @as(*const fn (*const BaseDriver) bool, &BaseDriver.isApRunning);
        _ = @as(*const fn (*const BaseDriver) []const StaInfo, &BaseDriver.getStaList);
        _ = @as(*const fn (*BaseDriver, Mac) void, &BaseDriver.deauthSta);

        _ = @as(*const fn (*BaseDriver, Protocol) void, &BaseDriver.setProtocol);
        _ = @as(*const fn (*BaseDriver, Bandwidth) void, &BaseDriver.setBandwidth);
        _ = @as(*const fn (*BaseDriver, [2]u8) void, &BaseDriver.setCountryCode);
        _ = @as(*const fn (*const BaseDriver) [2]u8, &BaseDriver.getCountryCode);

        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .wifi,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;

        driver: *Driver,
        state: State = .disconnected,
        current_ssid: ?[]const u8 = null,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn connect(self: *Self, ssid: []const u8, password: []const u8) void {
            self.state = .connecting;
            self.current_ssid = ssid;
            self.driver.connect(ssid, password);
        }

        pub fn connectWithConfig(self: *Self, config: ConnectConfig) void {
            self.state = .connecting;
            self.current_ssid = config.ssid;
            self.driver.connectWithConfig(config);
        }

        pub fn disconnect(self: *Self) void {
            self.driver.disconnect();
            self.state = .disconnected;
            self.current_ssid = null;
        }

        pub fn reconnect(self: *Self) void {
            self.state = .connecting;
            self.driver.reconnect();
        }

        pub fn pollEvent(self: *Self) ?WifiEvent {
            const event = self.driver.pollEvent() orelse return null;
            switch (event) {
                .connected => self.state = .connected,
                .disconnected => self.state = .disconnected,
                .connection_failed => self.state = .failed,
                else => {},
            }
            return event;
        }

        pub fn isConnected(self: *const Self) bool {
            return self.driver.isConnected();
        }

        pub fn getRssi(self: *const Self) ?i8 {
            return self.driver.getRssi();
        }

        pub fn getMac(self: *const Self) ?Mac {
            return self.driver.getMac();
        }

        pub fn getChannel(self: *const Self) ?u8 {
            return self.driver.getChannel();
        }

        pub fn getSsid(self: *const Self) ?[]const u8 {
            return self.driver.getSsid();
        }

        pub fn getBssid(self: *const Self) ?Mac {
            return self.driver.getBssid();
        }

        pub fn getPhyMode(self: *const Self) ?PhyMode {
            return self.driver.getPhyMode();
        }

        pub fn getState(self: *const Self) State {
            return self.state;
        }

        pub fn getStatus(self: *const Self) Status {
            return .{
                .state = self.state,
                .ip = null,
                .rssi = self.getRssi(),
                .ssid = self.getSsid(),
                .bssid = self.getBssid(),
                .channel = self.getChannel(),
                .phy_mode = self.getPhyMode(),
            };
        }

        pub fn scanStart(self: *Self, config: ScanConfig) Error!void {
            return self.driver.scanStart(config);
        }

        pub fn setPowerSave(self: *Self, mode: PowerSaveMode) void {
            self.driver.setPowerSave(mode);
        }

        pub fn getPowerSave(self: *const Self) PowerSaveMode {
            return self.driver.getPowerSave();
        }

        pub fn setRoaming(self: *Self, config: RoamingConfig) void {
            self.driver.setRoaming(config);
        }

        pub fn setRssiThreshold(self: *Self, rssi: i8) void {
            self.driver.setRssiThreshold(rssi);
        }

        pub fn setTxPower(self: *Self, power: i8) void {
            self.driver.setTxPower(power);
        }

        pub fn getTxPower(self: *const Self) ?i8 {
            return self.driver.getTxPower();
        }

        pub fn startAp(self: *Self, config: ApConfig) Error!void {
            try self.driver.startAp(config);
            self.state = .ap_running;
        }

        pub fn stopAp(self: *Self) void {
            self.driver.stopAp();
            self.state = .disconnected;
        }

        pub fn isApRunning(self: *const Self) bool {
            return self.driver.isApRunning();
        }

        pub fn getStaList(self: *const Self) []const StaInfo {
            return self.driver.getStaList();
        }

        pub fn deauthSta(self: *Self, mac: Mac) void {
            self.driver.deauthSta(mac);
        }

        pub fn setProtocol(self: *Self, proto: Protocol) void {
            self.driver.setProtocol(proto);
        }

        pub fn setBandwidth(self: *Self, bw: Bandwidth) void {
            self.driver.setBandwidth(bw);
        }

        pub fn setCountryCode(self: *Self, code: [2]u8) void {
            self.driver.setCountryCode(code);
        }

        pub fn getCountryCode(self: *const Self) [2]u8 {
            return self.driver.getCountryCode();
        }

        pub fn getSignalQuality(self: *const Self) ?u8 {
            const rssi = self.getRssi() orelse return null;
            if (rssi >= -50) return 100;
            if (rssi <= -100) return 0;
            const quality: i16 = @as(i16, rssi) + 100;
            return @intCast(@as(u16, @intCast(quality)) * 2);
        }

        pub fn formatIp(ip: IpAddress) [15]u8 {
            var buf: [15]u8 = [_]u8{0} ** 15;
            _ = std.fmt.bufPrint(&buf, "{}.{}.{}.{}", .{ ip[0], ip[1], ip[2], ip[3] }) catch {};
            return buf;
        }
    };
}
