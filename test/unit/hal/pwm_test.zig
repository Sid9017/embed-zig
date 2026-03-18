const std = @import("std");
const testing = std.testing;
const embed = @import("embed");

const pwm_mod = embed.hal.pwm;

test "pwm wrapper" {
    const Mock = struct {
        duty: [4]u16 = [_]u16{0} ** 4,
        freq: [4]u32 = [_]u32{0} ** 4,

        pub fn setDuty(self: *@This(), channel: u8, duty: u16) pwm_mod.Error!void {
            self.duty[channel] = duty;
        }
        pub fn getDuty(self: *@This(), channel: u8) pwm_mod.Error!u16 {
            return self.duty[channel];
        }
        pub fn setFrequency(self: *@This(), channel: u8, hz: u32) pwm_mod.Error!void {
            self.freq[channel] = hz;
        }
    };

    const Pwm = pwm_mod.from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "pwm.test" };
        pub const config = pwm_mod.Config{ .period_ticks = 1000, .frequency_hz = 1000 };
    });

    var d = Mock{};
    var pwm = Pwm.init(&d);
    try pwm.setPercent(0, 50);
    try std.testing.expectEqual(@as(u16, 500), try pwm.getDuty(0));
    try pwm.setFrequency(0, 2000);
    try std.testing.expectEqual(@as(u32, 2000), d.freq[0]);
}
