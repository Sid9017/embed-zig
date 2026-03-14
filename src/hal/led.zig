//! Single LED HAL wrapper.

const hal_marker = @import("marker.zig");

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .led;
}

/// spec must define:
/// - Driver.setDuty(*Driver, u16) void
/// - Driver.getDuty(*const Driver) u16
/// - Driver.fade(*Driver, u16, u32) void
/// - meta.id: []const u8
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };

    comptime {
        _ = @as(*const fn (*BaseDriver, u16) void, &BaseDriver.setDuty);
        _ = @as(*const fn (*const BaseDriver) u16, &BaseDriver.getDuty);
        _ = @as(*const fn (*BaseDriver, u16, u32) void, &BaseDriver.fade);
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .led,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;

        driver: *Driver,
        enabled: bool = true,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn setBrightness(self: *Self, brightness: u8) void {
            if (!self.enabled) return;
            const duty: u16 = @as(u16, brightness) * 257;
            self.driver.setDuty(duty);
        }

        pub fn getBrightness(self: *const Self) u8 {
            return @intCast(self.driver.getDuty() / 257);
        }

        pub fn setPercent(self: *Self, percent: u8) void {
            const p = @min(percent, 100);
            const brightness: u8 = @intCast((@as(u16, p) * 255) / 100);
            self.setBrightness(brightness);
        }

        pub fn getPercent(self: *const Self) u8 {
            return @intCast((@as(u16, self.getBrightness()) * 100) / 255);
        }

        pub fn fadeTo(self: *Self, brightness: u8, duration_ms: u32) void {
            if (!self.enabled) return;
            const target: u16 = @as(u16, brightness) * 257;
            self.driver.fade(target, duration_ms);
        }

        pub fn fadeIn(self: *Self, duration_ms: u32) void {
            self.fadeTo(255, duration_ms);
        }

        pub fn fadeOut(self: *Self, duration_ms: u32) void {
            self.fadeTo(0, duration_ms);
        }

        pub fn setEnabled(self: *Self, enabled: bool) void {
            self.enabled = enabled;
            if (!enabled) self.driver.setDuty(0);
        }

        pub fn isEnabled(self: Self) bool {
            return self.enabled;
        }

        pub fn on(self: *Self) void {
            self.setBrightness(255);
        }

        pub fn off(self: *Self) void {
            self.setBrightness(0);
        }

        pub fn toggle(self: *Self) void {
            if (self.getBrightness() > 0) self.off() else self.on();
        }

        pub fn isOn(self: *const Self) bool {
            return self.getBrightness() > 0;
        }
    };
}
