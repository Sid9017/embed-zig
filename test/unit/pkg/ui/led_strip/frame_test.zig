const std = @import("std");
const embed = @import("embed");
const frame = embed.pkg.ui.led_strip.frame;
const led_strip = embed.hal.led_strip;

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Frame: solid" {
    const F = frame.Frame(4);
    const f = F.solid(led_strip.Color.red);
    for (f.pixels) |p| {
        try testing.expectEqual(led_strip.Color.red, p);
    }
}

test "Frame: gradient endpoints" {
    const F = frame.Frame(8);
    const f = F.gradient(led_strip.Color.red, led_strip.Color.blue);
    try testing.expectEqual(led_strip.Color.red, f.pixels[0]);
    try testing.expectEqual(led_strip.Color.blue, f.pixels[7]);
}

test "Frame: rotate shifts left" {
    const F = frame.Frame(4);
    var f: F = .{};
    f.pixels[0] = led_strip.Color.red;
    f.pixels[1] = led_strip.Color.green;
    f.pixels[2] = led_strip.Color.blue;
    f.pixels[3] = led_strip.Color.white;
    const r = f.rotate();
    try testing.expectEqual(led_strip.Color.green, r.pixels[0]);
    try testing.expectEqual(led_strip.Color.blue, r.pixels[1]);
    try testing.expectEqual(led_strip.Color.white, r.pixels[2]);
    try testing.expectEqual(led_strip.Color.red, r.pixels[3]);
}

test "Frame: flip reverses" {
    const F = frame.Frame(3);
    var f: F = .{};
    f.pixels[0] = led_strip.Color.red;
    f.pixels[1] = led_strip.Color.green;
    f.pixels[2] = led_strip.Color.blue;
    const fl = f.flip();
    try testing.expectEqual(led_strip.Color.blue, fl.pixels[0]);
    try testing.expectEqual(led_strip.Color.green, fl.pixels[1]);
    try testing.expectEqual(led_strip.Color.red, fl.pixels[2]);
}

test "Frame: withBrightness scales" {
    const F = frame.Frame(1);
    const f = F.solid(led_strip.Color.white).withBrightness(128);
    try testing.expect(f.pixels[0].r < 200);
    try testing.expect(f.pixels[0].r > 100);
}

test "Frame: eql" {
    const F = frame.Frame(2);
    const a = F.solid(led_strip.Color.red);
    const b = F.solid(led_strip.Color.red);
    const c = F.solid(led_strip.Color.green);
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
}
