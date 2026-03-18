const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const framebuffer_mod = embed.pkg.ui.render.framebuffer;
const anim = embed.pkg.ui.render.anim;

// ============================================================================
// Tests
// ============================================================================

test "AnimPlayer: parse header" {
    var data: [14 + 4 + 2 + 8 + 2]u8 = undefined;
    data[0] = 2;
    data[1] = 0;
    data[2] = 2;
    data[3] = 0;
    data[4] = 1;
    data[5] = 0;
    data[6] = 1;
    data[7] = 0;
    data[8] = 1;
    data[9] = 0;
    data[10] = 15;
    data[11] = 2;
    data[12] = 2;
    data[13] = 0;
    data[14] = 0;
    data[15] = 0;
    data[16] = 0xFF;
    data[17] = 0xFF;
    data[18] = 1;
    data[19] = 0;
    data[20] = 0;
    data[21] = 0;
    data[22] = 0;
    data[23] = 0;
    data[24] = 1;
    data[25] = 0;
    data[26] = 1;
    data[27] = 0;
    data[28] = 0;
    data[29] = 1;

    var player = anim.AnimPlayer.init(&data) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(u16, 2), player.header.display_w);
    try testing.expectEqual(@as(u16, 1), player.header.frame_w);
    try testing.expectEqual(@as(u16, 1), player.header.frame_count);
    try testing.expectEqual(@as(u8, 15), player.header.fps);
    try testing.expectEqual(@as(u8, 2), player.header.scale);

    const frame = player.nextFrame() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), frame.rects.len);
    try testing.expectEqual(@as(u16, 0xFFFF), frame.rects[0].pixels[0]);

    try testing.expectEqual(@as(?anim.AnimFrame, null), player.nextFrame());
    try testing.expect(player.isDone());
}

test "AnimPlayer: RLE decode multiple runs" {
    var data: [14 + 4 + 2 + 8 + 4]u8 = undefined;
    data[0] = 4;
    data[1] = 0;
    data[2] = 1;
    data[3] = 0;
    data[4] = 4;
    data[5] = 0;
    data[6] = 1;
    data[7] = 0;
    data[8] = 1;
    data[9] = 0;
    data[10] = 30;
    data[11] = 1;
    data[12] = 2;
    data[13] = 0;
    data[14] = 0;
    data[15] = 0;
    data[16] = 0xFF;
    data[17] = 0xFF;
    data[18] = 1;
    data[19] = 0;
    data[20] = 0;
    data[21] = 0;
    data[22] = 0;
    data[23] = 0;
    data[24] = 4;
    data[25] = 0;
    data[26] = 1;
    data[27] = 0;
    data[28] = 1;
    data[29] = 0;
    data[30] = 1;
    data[31] = 1;

    var player = anim.AnimPlayer.init(&data).?;
    const frame = player.nextFrame().?;

    try testing.expectEqual(@as(u16, 0x0000), frame.rects[0].pixels[0]);
    try testing.expectEqual(@as(u16, 0x0000), frame.rects[0].pixels[1]);
    try testing.expectEqual(@as(u16, 0xFFFF), frame.rects[0].pixels[2]);
    try testing.expectEqual(@as(u16, 0xFFFF), frame.rects[0].pixels[3]);
}

fn buildMultiFrameAnim() [14 + 4 + 3 * (2 + 8 + 2 * 2)]u8 {
    const HEADER = 14;
    const PAL = 4;
    const FRAME = 2 + 8 + 4;
    var d: [HEADER + PAL + 3 * FRAME]u8 = undefined;
    d[0] = 2;
    d[1] = 0;
    d[2] = 1;
    d[3] = 0;
    d[4] = 2;
    d[5] = 0;
    d[6] = 1;
    d[7] = 0;
    d[8] = 3;
    d[9] = 0;
    d[10] = 10;
    d[11] = 1;
    d[12] = 2;
    d[13] = 0;
    d[14] = 0;
    d[15] = 0;
    d[16] = 0xFF;
    d[17] = 0xFF;

    const base = HEADER + PAL;
    inline for (0..3) |f| {
        const off = base + f * FRAME;
        d[off] = 1;
        d[off + 1] = 0;
        d[off + 2] = 0;
        d[off + 3] = 0;
        d[off + 4] = 0;
        d[off + 5] = 0;
        d[off + 6] = 2;
        d[off + 7] = 0;
        d[off + 8] = 1;
        d[off + 9] = 0;
        const colors: [3][2]u8 = .{
            .{ 0, 1 },
            .{ 1, 0 },
            .{ 1, 1 },
        };
        d[off + 10] = 0;
        d[off + 11] = colors[f][0];
        d[off + 12] = 0;
        d[off + 13] = colors[f][1];
    }
    return d;
}

test "T1: multi-frame playback" {
    var data = buildMultiFrameAnim();
    var player = anim.AnimPlayer.init(&data).?;

    try testing.expectEqual(@as(u16, 3), player.header.frame_count);
    try testing.expect(!player.isDone());

    const f0 = player.nextFrame().?;
    try testing.expectEqual(@as(u16, 0), f0.frame_index);
    try testing.expectEqual(@as(u16, 0x0000), f0.rects[0].pixels[0]);
    try testing.expectEqual(@as(u16, 0xFFFF), f0.rects[0].pixels[1]);

    const f1 = player.nextFrame().?;
    try testing.expectEqual(@as(u16, 1), f1.frame_index);
    try testing.expectEqual(@as(u16, 0xFFFF), f1.rects[0].pixels[0]);
    try testing.expectEqual(@as(u16, 0x0000), f1.rects[0].pixels[1]);

    const f2 = player.nextFrame().?;
    try testing.expectEqual(@as(u16, 2), f2.frame_index);
    try testing.expectEqual(@as(u16, 0xFFFF), f2.rects[0].pixels[0]);
    try testing.expectEqual(@as(u16, 0xFFFF), f2.rects[0].pixels[1]);

    try testing.expect(player.nextFrame() == null);
    try testing.expect(player.isDone());
}

test "T2: loop playback — reset replays from frame 0" {
    var data = buildMultiFrameAnim();
    var player = anim.AnimPlayer.init(&data).?;

    _ = player.nextFrame().?;
    _ = player.nextFrame().?;
    _ = player.nextFrame().?;
    try testing.expect(player.isDone());

    player.reset();
    try testing.expect(!player.isDone());
    try testing.expectEqual(@as(u16, 0), player.frame_index);

    const f0 = player.nextFrame().?;
    try testing.expectEqual(@as(u16, 0), f0.frame_index);
    try testing.expectEqual(@as(u16, 0x0000), f0.rects[0].pixels[0]);
    try testing.expectEqual(@as(u16, 0xFFFF), f0.rects[0].pixels[1]);

    const f1 = player.nextFrame().?;
    try testing.expectEqual(@as(u16, 1), f1.frame_index);
}

test "T3: anim.blitAnimFrame writes correct pixels to framebuffer" {
    var data = buildMultiFrameAnim();
    var player = anim.AnimPlayer.init(&data).?;

    const FB = framebuffer_mod.Framebuffer(4, 4, .rgb565);
    var fb = FB.init(0x1234);

    const frame = player.nextFrame().?;
    anim.blitAnimFrame(4, 4, .rgb565, &fb, frame, 1);

    try testing.expectEqual(@as(u16, 0x0000), fb.getPixel(0, 0));
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(1, 0));
    try testing.expectEqual(@as(u16, 0x1234), fb.getPixel(2, 0));
    try testing.expectEqual(@as(u16, 0x1234), fb.getPixel(0, 1));

    var fb2 = FB.init(0x1234);
    anim.blitAnimFrame(4, 4, .rgb565, &fb2, frame, 2);

    try testing.expectEqual(@as(u16, 0x0000), fb2.getPixel(0, 0));
    try testing.expectEqual(@as(u16, 0x0000), fb2.getPixel(1, 0));
    try testing.expectEqual(@as(u16, 0x0000), fb2.getPixel(0, 1));
    try testing.expectEqual(@as(u16, 0x0000), fb2.getPixel(1, 1));
    try testing.expectEqual(@as(u16, 0xFFFF), fb2.getPixel(2, 0));
    try testing.expectEqual(@as(u16, 0xFFFF), fb2.getPixel(3, 0));
    try testing.expectEqual(@as(u16, 0xFFFF), fb2.getPixel(2, 1));
    try testing.expectEqual(@as(u16, 0xFFFF), fb2.getPixel(3, 1));
}

test "T4: malformed data does not crash" {
    try testing.expect(anim.AnimPlayer.init(&[_]u8{}) == null);
    try testing.expect(anim.AnimPlayer.init(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }) == null);

    var short: [14]u8 = undefined;
    @memset(&short, 0);
    short[12] = 100;
    try testing.expect(anim.AnimPlayer.init(&short) == null);

    var zero_frames: [14 + 4]u8 = undefined;
    @memset(&zero_frames, 0);
    zero_frames[12] = 2;
    zero_frames[14] = 0xAA;
    zero_frames[15] = 0xBB;
    zero_frames[16] = 0xCC;
    zero_frames[17] = 0xDD;
    var player = anim.AnimPlayer.init(&zero_frames).?;
    try testing.expect(player.isDone());
    try testing.expect(player.nextFrame() == null);

    var trunc: [14 + 4 + 2]u8 = undefined;
    @memset(&trunc, 0);
    trunc[8] = 1;
    trunc[12] = 2;
    trunc[18] = 1;
    trunc[19] = 0;
    var player2 = anim.AnimPlayer.init(&trunc).?;
    try testing.expect(player2.nextFrame() == null);
}
