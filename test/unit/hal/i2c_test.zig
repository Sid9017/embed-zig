const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const i2c = embed.hal.i2c;

test "i2c wrapper" {
    const Mock = struct {
        pub fn write(_: *@This(), _: u7, _: []const u8) i2c.Error!void {}
        pub fn writeRead(_: *@This(), _: u7, _: []const u8, out: []u8) i2c.Error!void {
            if (out.len > 0) out[0] = 0x42;
        }
    };

    const Dev = i2c.from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "i2c.test" };
    });

    var d = Mock{};
    var bus = Dev.init(&d);
    var out: [1]u8 = .{0};
    try bus.write(0x50, &[_]u8{0x00});
    try bus.writeRead(0x50, &[_]u8{0x00}, &out);
    try @import("std").testing.expectEqual(@as(u8, 0x42), out[0]);
}

test "i2c wrapper with device model" {
    const Mock = struct {
        pub const DeviceHandle = u8;

        pub fn registerDevice(_: *@This(), cfg: i2c.DeviceConfig) i2c.Error!DeviceHandle {
            _ = cfg;
            return 1;
        }
        pub fn unregisterDevice(_: *@This(), _: DeviceHandle) i2c.Error!void {}
        pub fn write(_: *@This(), _: DeviceHandle, _: []const u8) i2c.Error!void {}
        pub fn writeRead(_: *@This(), _: DeviceHandle, _: []const u8, out: []u8) i2c.Error!void {
            if (out.len > 0) out[0] = 0x7A;
        }
    };

    const Dev = i2c.from(struct {
        pub const Driver = Mock;
        pub const DeviceHandle = Mock.DeviceHandle;
        pub const meta = .{ .id = "i2c.test.device" };
    });

    var d = Mock{};
    var bus = Dev.init(&d);
    var sensor = try bus.initDevice(.{ .address = 0x40 });
    defer sensor.deinit();
    var out: [1]u8 = .{0};
    try sensor.writeRead(&[_]u8{0x00}, &out);
    try @import("std").testing.expectEqual(@as(u8, 0x7A), out[0]);
}
