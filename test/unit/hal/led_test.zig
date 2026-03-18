const std = @import("std");
const testing = std.testing;
const embed = @import("embed");

const led_mod = embed.hal.led;

test "led wrapper" {
    const Mock = struct {
        duty: u16 = 0,
        fade_target: u16 = 0,

        pub fn setDuty(self: *@This(), duty: u16) void {
            self.duty = duty;
        }
        pub fn getDuty(self: *const @This()) u16 {
            return self.duty;
        }
        pub fn fade(self: *@This(), target: u16, _: u32) void {
            self.fade_target = target;
            self.duty = target;
        }
    };

    const Led = led_mod.from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "led.test" };
    });

    var d = Mock{};
    var led = Led.init(&d);
    led.setBrightness(128);
    try std.testing.expect(led.getBrightness() >= 127 and led.getBrightness() <= 128);
    led.fadeIn(100);
    try std.testing.expectEqual(@as(u16, 65535), d.fade_target);
}
