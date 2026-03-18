const std = @import("std");
const testing = std.testing;
const embed = @import("embed");

const led_strip = embed.hal.led_strip;

test "led strip wrapper" {
    const Mock = struct {
        pixels: [8]led_strip.Color = [_]led_strip.Color{.black} ** 8,
        refresh_count: u32 = 0,

        pub fn setPixel(self: *@This(), index: u32, color: led_strip.Color) void {
            self.pixels[index] = color;
        }
        pub fn getPixelCount(_: *@This()) u32 {
            return 8;
        }
        pub fn refresh(self: *@This()) void {
            self.refresh_count += 1;
        }
    };

    const Strip = led_strip.from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "ledstrip.test" };
    });

    var d = Mock{};
    var strip = Strip.init(&d);
    strip.setColor(.red);
    try std.testing.expectEqual(led_strip.Color.red, d.pixels[0]);
    strip.setBrightness(128);
    strip.setColor(.white);
    try std.testing.expect(d.pixels[0].r < 200);
    strip.setEnabled(false);
    try std.testing.expectEqual(led_strip.Color.black, d.pixels[0]);
    try std.testing.expect(d.refresh_count > 0);
}
