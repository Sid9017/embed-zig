//! GPIO HAL wrapper.

const hal_marker = @import("marker.zig");

pub const Error = error{
    InvalidPin,
    InvalidMode,
    Busy,
    Timeout,
    GpioError,
};

pub const Level = enum(u1) {
    low = 0,
    high = 1,
};

pub const Mode = enum {
    input,
    output,
    input_output,
};

pub const Pull = enum {
    none,
    up,
    down,
};

pub const PinConfig = struct {
    mode: Mode,
    pull: Pull = .none,
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .gpio;
}

/// spec must define:
/// - Driver.setMode(*Driver, pin: u8, mode: Mode) Error!void
/// - Driver.setLevel(*Driver, pin: u8, level: Level) Error!void
/// - Driver.getLevel(*Driver, pin: u8) Error!Level
/// - Driver.setPull(*Driver, pin: u8, pull: Pull) Error!void
/// - meta.id: []const u8
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };

    comptime {
        _ = @as(*const fn (*BaseDriver, u8, Mode) Error!void, &BaseDriver.setMode);
        _ = @as(*const fn (*BaseDriver, u8, Level) Error!void, &BaseDriver.setLevel);
        _ = @as(*const fn (*BaseDriver, u8) Error!Level, &BaseDriver.getLevel);
        _ = @as(*const fn (*BaseDriver, u8, Pull) Error!void, &BaseDriver.setPull);

        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .gpio,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn configure(self: *Self, pin: u8, cfg: PinConfig) Error!void {
            try self.driver.setMode(pin, cfg.mode);
            try self.driver.setPull(pin, cfg.pull);
        }

        pub fn setLevel(self: *Self, pin: u8, level: Level) Error!void {
            return self.driver.setLevel(pin, level);
        }

        pub fn getLevel(self: *Self, pin: u8) Error!Level {
            return self.driver.getLevel(pin);
        }

        pub fn setHigh(self: *Self, pin: u8) Error!void {
            return self.setLevel(pin, .high);
        }

        pub fn setLow(self: *Self, pin: u8) Error!void {
            return self.setLevel(pin, .low);
        }

        pub fn toggle(self: *Self, pin: u8) Error!void {
            const cur = try self.getLevel(pin);
            return self.setLevel(pin, if (cur == .high) .low else .high);
        }
    };
}
