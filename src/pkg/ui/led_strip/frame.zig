const std = @import("std");
const embed = @import("../../../mod.zig");

const Color = embed.hal.led_strip.Color;

pub fn Frame(comptime n: u32) type {
    return struct {
        const Self = @This();
        pub const pixel_count = n;

        pixels: [n]Color = [_]Color{Color.black} ** n,

        pub fn solid(color: Color) Self {
            var f: Self = .{};
            @memset(&f.pixels, color);
            return f;
        }

        pub fn gradient(from: Color, to: Color) Self {
            var f: Self = .{};
            if (n <= 1) {
                f.pixels[0] = from;
                return f;
            }
            for (0..n) |i| {
                const t: u8 = @intCast((i * 255) / (n - 1));
                f.pixels[i] = Color.lerp(from, to, t);
            }
            return f;
        }

        pub fn rotate(self: Self) Self {
            var f: Self = .{};
            for (0..n - 1) |i| {
                f.pixels[i] = self.pixels[i + 1];
            }
            f.pixels[n - 1] = self.pixels[0];
            return f;
        }

        pub fn flip(self: Self) Self {
            var f: Self = .{};
            for (0..n) |i| {
                f.pixels[i] = self.pixels[n - 1 - i];
            }
            return f;
        }

        pub fn withBrightness(self: Self, brightness: u8) Self {
            var f: Self = .{};
            for (0..n) |i| {
                f.pixels[i] = self.pixels[i].withBrightness(brightness);
            }
            return f;
        }

        pub fn eql(a: Self, b: Self) bool {
            return std.mem.eql(Color, &a.pixels, &b.pixels);
        }
    };
}
