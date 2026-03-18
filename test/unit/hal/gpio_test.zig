const std = @import("std");
const testing = std.testing;
const embed = @import("embed");

const gpio_mod = embed.hal.gpio;

test "gpio wrapper" {
    const Mock = struct {
        pins: [8]gpio_mod.Level = [_]gpio_mod.Level{.low} ** 8,

        pub fn setMode(_: *@This(), _: u8, _: gpio_mod.Mode) gpio_mod.Error!void {}
        pub fn setLevel(self: *@This(), pin: u8, level: gpio_mod.Level) gpio_mod.Error!void {
            self.pins[pin] = level;
        }
        pub fn getLevel(self: *@This(), pin: u8) gpio_mod.Error!gpio_mod.Level {
            return self.pins[pin];
        }
        pub fn setPull(_: *@This(), _: u8, _: gpio_mod.Pull) gpio_mod.Error!void {}
    };

    const Gpio = gpio_mod.from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "gpio.test" };
    });

    var d = Mock{};
    var gpio = Gpio.init(&d);
    try gpio.configure(1, .{ .mode = .output, .pull = .none });
    try gpio.setHigh(1);
    try std.testing.expectEqual(gpio_mod.Level.high, try gpio.getLevel(1));
    try gpio.toggle(1);
    try std.testing.expectEqual(gpio_mod.Level.low, try gpio.getLevel(1));
}
