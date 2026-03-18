const std = @import("std");
const testing = std.testing;
const embed = @import("embed");

const imu_mod = embed.hal.imu;

test "imu 6-axis wrapper" {
    const Mock = struct {
        pub fn readAccel(_: *@This()) imu_mod.Error!imu_mod.AccelData {
            return .{ .x = 0.1, .y = 0.2, .z = 1.0 };
        }
        pub fn readGyro(_: *@This()) imu_mod.Error!imu_mod.GyroData {
            return .{ .x = 10, .y = 20, .z = 30 };
        }
        pub fn readMag(_: *@This()) imu_mod.Error!imu_mod.MagData {
            return .{ .x = 1, .y = 2, .z = 3 };
        }
        pub fn isDataReady(_: *@This()) imu_mod.Error!bool {
            return true;
        }
    };

    const Imu = imu_mod.from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "imu.test" };
    });

    var d = Mock{};
    var imu = Imu.init(&d);
    const acc = try imu.readAccel();
    const gyr = try imu.readGyro();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), acc.z, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), gyr.x, 0.001);
}
