const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const led_strip = embed.hal.led_strip;
const led_strip_mod = embed.websim.hal.led_strip;

test "websim led_strip satisfies hal contract" {
    const LedStripHal = embed.hal.led_strip.from(struct {
        pub const Driver = led_strip_mod.LedStrip;
        pub const meta = .{ .id = "led_strip.websim" };
    });

    var drv = led_strip_mod.LedStrip.init();
    var strip = LedStripHal.init(&drv);

    try std.testing.expectEqual(@as(u32, 1), strip.getPixelCount());

    strip.setPixel(0, led_strip.Color.red);
    try std.testing.expectEqual(led_strip.Color.red, drv.pixels[0]);
}
