const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const gpio_hal = embed.hal.gpio;
const Level = gpio_hal.Level;
const gpio = embed.websim.hal.gpio;

test "websim gpio satisfies hal contract" {
    const GpioHal = gpio_hal.from(struct {
        pub const Driver = gpio.Gpio;
        pub const meta = .{ .id = "gpio.websim" };
    });

    var drv = gpio.Gpio.init();
    var g = GpioHal.init(&drv);
    try g.configure(0, .{ .mode = .input });
    try std.testing.expectEqual(Level.high, try g.getLevel(0));

    drv.injectLevel(0, .low);
    try std.testing.expectEqual(Level.low, try g.getLevel(0));

    drv.injectLevel(0, .high);
    try std.testing.expectEqual(Level.high, try g.getLevel(0));
}

test "websim gpio rejects invalid pin" {
    var drv = gpio.Gpio.init();
    try std.testing.expectError(error.InvalidPin, drv.getLevel(gpio.max_pins));
    try std.testing.expectError(error.InvalidPin, drv.setLevel(gpio.max_pins, .high));
}
