const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const wifi_mod = embed.hal.wifi;

test "wifi event-driven operations" {
    const MockDriver = struct {
        connected: bool = false,
        pending_event: ?wifi_mod.WifiEvent = null,
        ssid: ?[]const u8 = null,
        ps: wifi_mod.PowerSaveMode = .none,
        tx_power: i8 = 20,
        ap_running: bool = false,
        country: [2]u8 = "01".*,

        pub fn connect(self: *@This(), ssid: []const u8, _: []const u8) void {
            self.connected = true;
            self.ssid = ssid;
            self.pending_event = .{ .connected = {} };
        }
        pub fn connectWithConfig(self: *@This(), config: wifi_mod.ConnectConfig) void {
            self.connect(config.ssid, config.password);
        }
        pub fn disconnect(self: *@This()) void {
            self.connected = false;
            self.ssid = null;
        }
        pub fn reconnect(self: *@This()) void {
            self.connected = true;
        }
        pub fn isConnected(self: *const @This()) bool {
            return self.connected;
        }
        pub fn pollEvent(self: *@This()) ?wifi_mod.WifiEvent {
            const ev = self.pending_event;
            self.pending_event = null;
            return ev;
        }
        pub fn getRssi(_: *const @This()) ?i8 {
            return -60;
        }
        pub fn getMac(_: *const @This()) ?wifi_mod.Mac {
            return .{ 1, 2, 3, 4, 5, 6 };
        }
        pub fn getChannel(_: *const @This()) ?u8 {
            return 6;
        }
        pub fn getSsid(self: *const @This()) ?[]const u8 {
            return self.ssid;
        }
        pub fn getBssid(_: *const @This()) ?wifi_mod.Mac {
            return .{ 6, 5, 4, 3, 2, 1 };
        }
        pub fn getPhyMode(_: *const @This()) ?wifi_mod.PhyMode {
            return .@"11n";
        }
        pub fn scanStart(_: *@This(), _: wifi_mod.ScanConfig) wifi_mod.Error!void {}
        pub fn setPowerSave(self: *@This(), mode: wifi_mod.PowerSaveMode) void {
            self.ps = mode;
        }
        pub fn getPowerSave(self: *const @This()) wifi_mod.PowerSaveMode {
            return self.ps;
        }
        pub fn setRoaming(_: *@This(), _: wifi_mod.RoamingConfig) void {}
        pub fn setRssiThreshold(_: *@This(), _: i8) void {}
        pub fn setTxPower(self: *@This(), power: i8) void {
            self.tx_power = power;
        }
        pub fn getTxPower(self: *const @This()) ?i8 {
            return self.tx_power;
        }
        pub fn startAp(self: *@This(), _: wifi_mod.ApConfig) wifi_mod.Error!void {
            self.ap_running = true;
        }
        pub fn stopAp(self: *@This()) void {
            self.ap_running = false;
        }
        pub fn isApRunning(self: *const @This()) bool {
            return self.ap_running;
        }
        pub fn getStaList(_: *const @This()) []const wifi_mod.StaInfo {
            return &[_]wifi_mod.StaInfo{};
        }
        pub fn deauthSta(_: *@This(), _: wifi_mod.Mac) void {}
        pub fn setProtocol(_: *@This(), _: wifi_mod.Protocol) void {}
        pub fn setBandwidth(_: *@This(), _: wifi_mod.Bandwidth) void {}
        pub fn setCountryCode(self: *@This(), code: [2]u8) void {
            self.country = code;
        }
        pub fn getCountryCode(self: *const @This()) [2]u8 {
            return self.country;
        }
    };

    const Wifi = wifi_mod.from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "wifi.test" };
    });

    var d = MockDriver{};
    var wifi = Wifi.init(&d);
    wifi.connect("Test", "pw");
    try std.testing.expectEqual(wifi_mod.State.connecting, wifi.getState());
    const ev = wifi.pollEvent() orelse return error.ExpectedEvent;
    try std.testing.expectEqual(wifi_mod.WifiEvent{ .connected = {} }, ev);
    try std.testing.expectEqual(wifi_mod.State.connected, wifi.getState());

    wifi.disconnect();
    try std.testing.expectEqual(wifi_mod.State.disconnected, wifi.getState());
    try std.testing.expectEqual(@as(?[]const u8, null), wifi.getSsid());
}

test "wifi signal quality" {
    const MockDriver = struct {
        rssi: i8 = -75,
        country: [2]u8 = "01".*,

        pub fn connect(_: *@This(), _: []const u8, _: []const u8) void {}
        pub fn connectWithConfig(_: *@This(), _: wifi_mod.ConnectConfig) void {}
        pub fn disconnect(_: *@This()) void {}
        pub fn reconnect(_: *@This()) void {}
        pub fn isConnected(_: *const @This()) bool {
            return true;
        }
        pub fn pollEvent(_: *@This()) ?wifi_mod.WifiEvent {
            return null;
        }
        pub fn getRssi(self: *const @This()) ?i8 {
            return self.rssi;
        }
        pub fn getMac(_: *const @This()) ?wifi_mod.Mac {
            return null;
        }
        pub fn getChannel(_: *const @This()) ?u8 {
            return null;
        }
        pub fn getSsid(_: *const @This()) ?[]const u8 {
            return null;
        }
        pub fn getBssid(_: *const @This()) ?wifi_mod.Mac {
            return null;
        }
        pub fn getPhyMode(_: *const @This()) ?wifi_mod.PhyMode {
            return null;
        }
        pub fn scanStart(_: *@This(), _: wifi_mod.ScanConfig) wifi_mod.Error!void {}
        pub fn setPowerSave(_: *@This(), _: wifi_mod.PowerSaveMode) void {}
        pub fn getPowerSave(_: *const @This()) wifi_mod.PowerSaveMode {
            return .none;
        }
        pub fn setRoaming(_: *@This(), _: wifi_mod.RoamingConfig) void {}
        pub fn setRssiThreshold(_: *@This(), _: i8) void {}
        pub fn setTxPower(_: *@This(), _: i8) void {}
        pub fn getTxPower(_: *const @This()) ?i8 {
            return null;
        }
        pub fn startAp(_: *@This(), _: wifi_mod.ApConfig) wifi_mod.Error!void {}
        pub fn stopAp(_: *@This()) void {}
        pub fn isApRunning(_: *const @This()) bool {
            return false;
        }
        pub fn getStaList(_: *const @This()) []const wifi_mod.StaInfo {
            return &[_]wifi_mod.StaInfo{};
        }
        pub fn deauthSta(_: *@This(), _: wifi_mod.Mac) void {}
        pub fn setProtocol(_: *@This(), _: wifi_mod.Protocol) void {}
        pub fn setBandwidth(_: *@This(), _: wifi_mod.Bandwidth) void {}
        pub fn setCountryCode(self: *@This(), code: [2]u8) void {
            self.country = code;
        }
        pub fn getCountryCode(self: *const @This()) [2]u8 {
            return self.country;
        }
    };

    const Wifi = wifi_mod.from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "wifi.quality" };
    });

    var d = MockDriver{};
    var wifi = Wifi.init(&d);
    try std.testing.expectEqual(@as(?u8, 50), wifi.getSignalQuality());
}
