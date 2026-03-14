//! SPI HAL contract wrapper.

const hal_marker = @import("marker.zig");

pub const Error = error{
    TransferFailed,
    Busy,
    Timeout,
    InvalidParam,
    SpiError,
};

/// Per-device registration parameters on an SPI master bus.
pub const DeviceConfig = struct {
    chip_select: i32,
    mode: u2 = 0,
    clock_hz: u32 = 1_000_000,
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .spi;
}

/// spec supports two models:
///
/// Legacy model:
/// - Driver.write(*Driver, []const u8) !void
/// - Driver.transfer(*Driver, []const u8, []u8) !void
/// - Driver.read(*Driver, []u8) !void
///
/// Bus+device model (preferred):
/// - DeviceHandle type in `spec.DeviceHandle`
/// - Driver.registerDevice(*Driver, DeviceConfig) !DeviceHandle
/// - Driver.unregisterDevice(*Driver, DeviceHandle) !void
/// - Driver.write(*Driver, DeviceHandle, []const u8) !void
/// - Driver.transfer(*Driver, DeviceHandle, []const u8, []u8) !void
/// - Driver.read(*Driver, DeviceHandle, []u8) !void
///
/// Common:
/// - meta.id: []const u8
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };
    const has_device_model = comptime @hasDecl(BaseDriver, "registerDevice");
    const DeviceHandle = if (has_device_model)
        if (@hasDecl(spec, "DeviceHandle"))
            spec.DeviceHandle
        else
            @compileError("SPI device model requires spec.DeviceHandle")
    else
        void;

    comptime {
        if (has_device_model) {
            _ = @as(*const fn (*BaseDriver, DeviceConfig) Error!DeviceHandle, &BaseDriver.registerDevice);
            _ = @as(*const fn (*BaseDriver, DeviceHandle) Error!void, &BaseDriver.unregisterDevice);
            _ = @as(*const fn (*BaseDriver, DeviceHandle, []const u8) Error!void, &BaseDriver.write);
            _ = @as(*const fn (*BaseDriver, DeviceHandle, []const u8, []u8) Error!void, &BaseDriver.transfer);
            _ = @as(*const fn (*BaseDriver, DeviceHandle, []u8) Error!void, &BaseDriver.read);
        } else {
            _ = @as(*const fn (*BaseDriver, []const u8) Error!void, &BaseDriver.write);
            _ = @as(*const fn (*BaseDriver, []const u8, []u8) Error!void, &BaseDriver.transfer);
            _ = @as(*const fn (*BaseDriver, []u8) Error!void, &BaseDriver.read);
        }
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .spi,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const DeviceHandleType = DeviceHandle;
        pub const meta = spec.meta;

        driver: *Driver,
        device: if (has_device_model) ?DeviceHandle else void =
            if (has_device_model) null else {},

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn initDevice(driver: *Driver, cfg: DeviceConfig) Error!Self {
            if (!comptime has_device_model) {
                @compileError("SPI legacy driver has no registerDevice; use init()");
            }
            const dev = try driver.registerDevice(cfg);
            return .{ .driver = driver, .device = dev };
        }

        pub fn deinitDevice(self: *Self) void {
            if (!comptime has_device_model) return;
            if (self.device) |dev| {
                self.driver.unregisterDevice(dev) catch {};
                self.device = null;
            }
        }

        pub fn write(self: *Self, data: []const u8) Error!void {
            if (comptime has_device_model) {
                const dev = self.device orelse return error.InvalidParam;
                return self.driver.write(dev, data);
            }
            return self.driver.write(data);
        }

        pub fn transfer(self: *Self, tx: []const u8, rx: []u8) Error!void {
            if (comptime has_device_model) {
                const dev = self.device orelse return error.InvalidParam;
                return self.driver.transfer(dev, tx, rx);
            }
            return self.driver.transfer(tx, rx);
        }

        pub fn read(self: *Self, buf: []u8) Error!void {
            if (comptime has_device_model) {
                const dev = self.device orelse return error.InvalidParam;
                return self.driver.read(dev, buf);
            }
            return self.driver.read(buf);
        }

        pub fn usesDeviceModel() bool {
            return has_device_model;
        }
    };
}
