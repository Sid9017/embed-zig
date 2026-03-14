//! I2C HAL contract wrapper.

const hal_marker = @import("marker.zig");

pub const Error = error{
    InitFailed,
    NoAck,
    Timeout,
    ArbitrationLost,
    InvalidParam,
    Busy,
    I2cError,
};

/// Per-device registration parameters on an I2C master bus.
pub const DeviceConfig = struct {
    address: u7,
    timeout_ms: u32 = 1000,
};

pub const Config = struct {
    sda: u8,
    scl: u8,
    freq_hz: u32 = 400_000,
    port: u8 = 0,
    pullup_en: bool = true,
    timeout_ms: u32 = 1000,
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .i2c;
}

/// spec must define:
/// Legacy model:
/// - Driver.write(*Driver, u7, []const u8) !void
/// - Driver.writeRead(*Driver, u7, []const u8, []u8) !void
///
/// Bus+device model (preferred):
/// - DeviceHandle type in `spec.DeviceHandle`
/// - Driver.registerDevice(*Driver, DeviceConfig) !DeviceHandle
/// - Driver.unregisterDevice(*Driver, DeviceHandle) !void
/// - Driver.write(*Driver, DeviceHandle, []const u8) !void
/// - Driver.writeRead(*Driver, DeviceHandle, []const u8, []u8) !void
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
            @compileError("I2C device model requires spec.DeviceHandle")
    else
        void;

    comptime {
        if (has_device_model) {
            _ = @as(*const fn (*BaseDriver, DeviceConfig) Error!DeviceHandle, &BaseDriver.registerDevice);
            _ = @as(*const fn (*BaseDriver, DeviceHandle) Error!void, &BaseDriver.unregisterDevice);
            _ = @as(*const fn (*BaseDriver, DeviceHandle, []const u8) Error!void, &BaseDriver.write);
            _ = @as(*const fn (*BaseDriver, DeviceHandle, []const u8, []u8) Error!void, &BaseDriver.writeRead);
        } else {
            _ = @as(*const fn (*BaseDriver, u7, []const u8) Error!void, &BaseDriver.write);
            _ = @as(*const fn (*BaseDriver, u7, []const u8, []u8) Error!void, &BaseDriver.writeRead);
        }
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();
        const uses_device_model = has_device_model;

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .i2c,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const DeviceHandleType = DeviceHandle;
        pub const meta = spec.meta;

        driver: *Driver,

        pub const Device = struct {
            driver: *Driver,
            address: u7,
            timeout_ms: u32 = 1000,
            handle: if (uses_device_model) ?DeviceHandle else void =
                if (uses_device_model) null else {},
            active: bool = true,

            pub fn deinit(self: *Device) void {
                if (!self.active) return;
                if (comptime uses_device_model) {
                    if (self.handle) |h| {
                        self.driver.unregisterDevice(h) catch {};
                        self.handle = null;
                    }
                }
                self.active = false;
            }

            pub fn write(self: *Device, data: []const u8) Error!void {
                if (!self.active) return error.InvalidParam;
                if (comptime uses_device_model) {
                    const h = self.handle orelse return error.InvalidParam;
                    return self.driver.write(h, data);
                }
                return self.driver.write(self.address, data);
            }

            pub fn writeRead(self: *Device, write_data: []const u8, read_buf: []u8) Error!void {
                if (!self.active) return error.InvalidParam;
                if (comptime uses_device_model) {
                    const h = self.handle orelse return error.InvalidParam;
                    return self.driver.writeRead(h, write_data, read_buf);
                }
                return self.driver.writeRead(self.address, write_data, read_buf);
            }
        };

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn initDevice(self: *Self, cfg: DeviceConfig) Error!Device {
            if (comptime uses_device_model) {
                const h = try self.driver.registerDevice(cfg);
                return .{
                    .driver = self.driver,
                    .address = cfg.address,
                    .timeout_ms = cfg.timeout_ms,
                    .handle = h,
                    .active = true,
                };
            }
            return .{
                .driver = self.driver,
                .address = cfg.address,
                .timeout_ms = cfg.timeout_ms,
            };
        }

        pub fn write(self: *Self, address: u7, data: []const u8) Error!void {
            // Compatibility path for legacy callsites when device model is enabled.
            // Prefer initDevice() + Device.write() to avoid per-call registration overhead.
            if (comptime uses_device_model) {
                const h = try self.driver.registerDevice(.{ .address = address });
                defer self.driver.unregisterDevice(h) catch {};
                return self.driver.write(h, data);
            }
            return self.driver.write(address, data);
        }

        pub fn writeRead(self: *Self, address: u7, write_data: []const u8, read_buf: []u8) Error!void {
            if (comptime uses_device_model) {
                const h = try self.driver.registerDevice(.{ .address = address });
                defer self.driver.unregisterDevice(h) catch {};
                return self.driver.writeRead(h, write_data, read_buf);
            }
            return self.driver.writeRead(address, write_data, read_buf);
        }

        pub fn usesDeviceModel() bool {
            return uses_device_model;
        }
    };
}
