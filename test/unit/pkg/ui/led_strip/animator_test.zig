const std = @import("std");
const embed = @import("embed");
const frame_mod = embed.pkg.ui.led_strip.frame;
const animator = embed.pkg.ui.led_strip.animator;
const led_strip = embed.hal.led_strip;

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Frame = frame_mod.Frame;

test "Animator: fixed converges to target" {
    const F = Frame(4);
    const Anim = animator.Animator(4, 4);
    var anim = Anim.fixed(F.solid(led_strip.Color.red));
    anim.step_amount = 50;

    var ticks: u32 = 0;
    while (!anim.current.eql(F.solid(led_strip.Color.red))) : (ticks += 1) {
        _ = anim.tick();
        if (ticks > 100) break;
    }
    try testing.expect(anim.current.eql(F.solid(led_strip.Color.red)));
}

test "Animator: flash alternates" {
    const F = Frame(1);
    const Anim = animator.Animator(1, 4);
    var anim = Anim.flash(F.solid(led_strip.Color.white), 2);
    anim.step_amount = 255;

    _ = anim.tick();
    _ = anim.tick();
    const after_first_interval = anim.current;

    _ = anim.tick();
    _ = anim.tick();
    const after_second_interval = anim.current;

    try testing.expect(!after_first_interval.eql(after_second_interval));
}

test "Animator: zero frames returns false" {
    const Anim = animator.Animator(2, 4);
    var anim = Anim{};
    try testing.expect(!anim.tick());
}

test "Animator: brightness scales output" {
    const F = Frame(1);
    const Anim = animator.Animator(1, 4);
    var anim = Anim.fixed(F.solid(led_strip.Color.white));
    anim.brightness = 128;
    anim.step_amount = 255;

    _ = anim.tick();
    try testing.expect(anim.current.pixels[0].r < 200);
    try testing.expect(anim.current.pixels[0].r > 50);
}

test "Animator: rotateAnim generates rotated frames" {
    const F = Frame(4);
    const Anim = animator.Animator(4, 4);
    var f: F = .{};
    f.pixels[0] = led_strip.Color.red;
    f.pixels[1] = led_strip.Color.green;
    f.pixels[2] = led_strip.Color.blue;
    f.pixels[3] = led_strip.Color.white;

    const anim = Anim.rotateAnim(f, 8);
    try testing.expectEqual(@as(u8, 4), anim.total_frames);
    try testing.expectEqual(led_strip.Color.green, anim.frames[1].pixels[0]);
    try testing.expectEqual(led_strip.Color.blue, anim.frames[2].pixels[0]);
}
