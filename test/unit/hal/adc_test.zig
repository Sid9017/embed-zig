const std = @import("std");
const testing = std.testing;
const embed = @import("embed");

const adc_mod = embed.hal.adc;

test "adc wrapper" {
    const Mock = struct {
        pub fn read(_: *@This(), channel: u8) adc_mod.Error!u16 {
            return 100 + channel;
        }
        pub fn readMv(self: *@This(), channel: u8) adc_mod.Error!u16 {
            const raw = try self.read(channel);
            return @intCast((@as(u32, raw) * 3300) / 4095);
        }
    };

    const Adc = adc_mod.from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "adc.test" };
        pub const config = adc_mod.Config{ .resolution = .bits_12, .vref_mv = 3300 };
    });

    var d = Mock{};
    var adc = Adc.init(&d);
    try std.testing.expectEqual(@as(u16, 101), try adc.read(1));
    try std.testing.expect((try adc.readMv(0)) > 0);
}
