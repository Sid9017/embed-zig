const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const spi = embed.hal.spi;

test "spi wrapper" {
    const Mock = struct {
        pub fn write(_: *@This(), _: []const u8) spi.Error!void {}
        pub fn transfer(_: *@This(), tx: []const u8, rx: []u8) spi.Error!void {
            const n = @min(tx.len, rx.len);
            @memcpy(rx[0..n], tx[0..n]);
        }
        pub fn read(_: *@This(), _: []u8) spi.Error!void {}
    };

    const Dev = spi.from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "spi.test" };
    });

    var d = Mock{};
    var bus = Dev.init(&d);
    var rx: [3]u8 = .{ 0, 0, 0 };
    try bus.transfer(&[_]u8{ 1, 2, 3 }, &rx);
    try @import("std").testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, &rx);
}

test "spi wrapper with device model" {
    const Mock = struct {
        pub const DeviceHandle = u8;

        pub fn registerDevice(_: *@This(), _: spi.DeviceConfig) spi.Error!DeviceHandle {
            return 1;
        }
        pub fn unregisterDevice(_: *@This(), _: DeviceHandle) spi.Error!void {}
        pub fn write(_: *@This(), _: DeviceHandle, _: []const u8) spi.Error!void {}
        pub fn transfer(_: *@This(), _: DeviceHandle, tx: []const u8, rx: []u8) spi.Error!void {
            const n = @min(tx.len, rx.len);
            @memcpy(rx[0..n], tx[0..n]);
        }
        pub fn read(_: *@This(), _: DeviceHandle, _: []u8) spi.Error!void {}
    };

    const Dev = spi.from(struct {
        pub const Driver = Mock;
        pub const DeviceHandle = Mock.DeviceHandle;
        pub const meta = .{ .id = "spi.test.device" };
    });

    var d = Mock{};
    var dev = try Dev.initDevice(&d, .{ .chip_select = 10, .mode = 0, .clock_hz = 4_000_000 });
    defer dev.deinitDevice();
    var rx: [3]u8 = .{ 0, 0, 0 };
    try dev.transfer(&[_]u8{ 7, 8, 9 }, &rx);
    try @import("std").testing.expectEqualSlices(u8, &[_]u8{ 7, 8, 9 }, &rx);
}
