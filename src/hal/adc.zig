//! ADC HAL wrapper.

const hal_marker = @import("marker.zig");

pub const Error = error{
    InvalidChannel,
    Busy,
    Timeout,
    AdcError,
};

pub const Resolution = enum(u8) {
    bits_8 = 8,
    bits_9 = 9,
    bits_10 = 10,
    bits_11 = 11,
    bits_12 = 12,
    bits_13 = 13,
    bits_14 = 14,
    bits_15 = 15,
    bits_16 = 16,
};

pub const Config = struct {
    resolution: Resolution = .bits_12,
    /// ADC full-scale reference in mV (for raw->mV fallback conversion)
    vref_mv: u16 = 1100,
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .adc;
}

/// spec must define:
/// - Driver.read(*Driver, channel: u8) Error!u16
/// - Driver.readMv(*Driver, channel: u8) Error!u16
/// - meta.id: []const u8
/// - config: Config (optional)
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };
    const has_spec_config = comptime @hasDecl(spec, "config");

    comptime {
        _ = @as(*const fn (*BaseDriver, u8) Error!u16, &BaseDriver.read);
        _ = @as(*const fn (*BaseDriver, u8) Error!u16, &BaseDriver.readMv);

        _ = @as([]const u8, spec.meta.id);
        if (has_spec_config) {
            _ = @as(Config, spec.config);
        }
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .adc,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;
        pub const config: Config = if (has_spec_config) spec.config else .{};

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn read(self: *Self, channel: u8) Error!u16 {
            return self.driver.read(channel);
        }

        pub fn readMv(self: *Self, channel: u8) Error!u16 {
            return self.driver.readMv(channel);
        }

        pub fn rawToMillivolts(raw: u16, resolution: Resolution, vref_mv: u16) u16 {
            const max_raw: u32 = switch (resolution) {
                .bits_8 => (1 << 8) - 1,
                .bits_9 => (1 << 9) - 1,
                .bits_10 => (1 << 10) - 1,
                .bits_11 => (1 << 11) - 1,
                .bits_12 => (1 << 12) - 1,
                .bits_13 => (1 << 13) - 1,
                .bits_14 => (1 << 14) - 1,
                .bits_15 => (1 << 15) - 1,
                .bits_16 => (1 << 16) - 1,
            };
            return @intCast((@as(u32, raw) * vref_mv) / max_raw);
        }
    };
}
