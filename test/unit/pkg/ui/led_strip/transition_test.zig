const std = @import("std");
const embed = @import("embed");
const frame_mod = embed.pkg.ui.led_strip.frame;
const led_strip = embed.hal.led_strip;
const transition = embed.pkg.ui.led_strip.transition;

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Frame = frame_mod.Frame;

test "stepToward: reaches target" {
    var c = led_strip.Color.black;
    const target = led_strip.Color.rgb(50, 100, 150);
    for (0..256) |_| {
        c = transition.stepToward(c, target, 5);
    }
    try testing.expectEqual(target, c);
}

test "stepToward: single step within range snaps" {
    const c = led_strip.Color.rgb(3, 3, 3);
    const t = led_strip.Color.black;
    const r = transition.stepToward(c, t, 5);
    try testing.expectEqual(led_strip.Color.black, r);
}

test "stepFrame: converges" {
    const F = Frame(4);
    var current = F.solid(led_strip.Color.black);
    const target = F.solid(led_strip.Color.red);
    var steps: u32 = 0;
    while (!current.eql(target)) : (steps += 1) {
        _ = transition.stepFrame(4, &current, target, 10);
        if (steps > 100) break;
    }
    try testing.expect(current.eql(target));
}

test "lerpFrame: remaining=1 snaps to target" {
    const F = Frame(2);
    var current = F.solid(led_strip.Color.black);
    const target = F.solid(led_strip.Color.white);
    const changed = transition.lerpFrame(2, &current, target, 1);
    try testing.expect(changed);
    try testing.expect(current.eql(target));
}

test "lerpFrame: converges over steps" {
    const F = Frame(2);
    var current = F.solid(led_strip.Color.black);
    const target = F.solid(led_strip.Color.rgb(100, 200, 50));
    for (0..64) |_| {
        _ = transition.lerpFrame(2, &current, target, 8);
    }
    try testing.expect(current.eql(target));
}
