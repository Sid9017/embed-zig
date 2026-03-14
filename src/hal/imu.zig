//! IMU HAL wrapper.

const hal_marker = @import("marker.zig");

pub const Error = error{
    NotReady,
    Timeout,
    InvalidData,
    BusError,
    SensorError,
};

pub const AccelData = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

pub const GyroData = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

pub const MagData = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .imu;
}

pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };

    comptime {
        _ = @as(*const fn (*BaseDriver) Error!AccelData, &BaseDriver.readAccel);
        _ = @as(*const fn (*BaseDriver) Error!GyroData, &BaseDriver.readGyro);
        _ = @as(*const fn (*BaseDriver) Error!MagData, &BaseDriver.readMag);
        _ = @as(*const fn (*BaseDriver) Error!bool, &BaseDriver.isDataReady);

        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .imu,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;

        pub const has_accel = true;
        pub const has_gyro = true;
        pub const has_mag = true;

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn readAccel(self: *Self) Error!AccelData {
            return self.driver.readAccel();
        }

        pub fn readGyro(self: *Self) Error!GyroData {
            return self.driver.readGyro();
        }

        pub fn readMag(self: *Self) Error!MagData {
            return self.driver.readMag();
        }

        pub fn isDataReady(self: *Self) Error!bool {
            return self.driver.isDataReady();
        }
    };
}
