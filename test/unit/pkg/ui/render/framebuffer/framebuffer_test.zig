const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const framebuffer = embed.pkg.ui.render.framebuffer;

// ============================================================================
// Tests
// ============================================================================

const TestFB = framebuffer.Framebuffer(16, 16, .rgb565);

test "init fills buffer" {
    const fb = TestFB.init(0x1234);
    try testing.expectEqual(@as(u16, 0x1234), fb.getPixel(0, 0));
    try testing.expectEqual(@as(u16, 0x1234), fb.getPixel(15, 15));
}

test "setPixel and getPixel" {
    var fb = TestFB.init(0);
    fb.setPixel(5, 7, 0xF800);
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(5, 7));
    try testing.expectEqual(@as(u16, 0), fb.getPixel(5, 6));
}

test "setPixel out of bounds is no-op" {
    var fb = TestFB.init(0);
    fb.setPixel(16, 0, 0xFFFF);
    fb.setPixel(0, 16, 0xFFFF);
    try testing.expectEqual(@as(u16, 0), fb.getPixel(15, 15));
}

test "getPixel out of bounds returns 0" {
    const fb = TestFB.init(0x1234);
    try testing.expectEqual(@as(u16, 0), fb.getPixel(16, 0));
    try testing.expectEqual(@as(u16, 0), fb.getPixel(0, 16));
}

test "fillRect writes pixels" {
    var fb = TestFB.init(0);
    fb.fillRect(2, 3, 4, 5, 0x07E0);

    try testing.expectEqual(@as(u16, 0x07E0), fb.getPixel(2, 3));
    try testing.expectEqual(@as(u16, 0x07E0), fb.getPixel(5, 7));

    try testing.expectEqual(@as(u16, 0), fb.getPixel(1, 3));
    try testing.expectEqual(@as(u16, 0), fb.getPixel(6, 3));
    try testing.expectEqual(@as(u16, 0), fb.getPixel(2, 2));
    try testing.expectEqual(@as(u16, 0), fb.getPixel(2, 8));
}

test "fillRect clips to bounds" {
    var fb = TestFB.init(0);
    fb.fillRect(14, 14, 10, 10, 0xFFFF);

    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(14, 14));
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(15, 15));
}

test "fillRect marks dirty" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    fb.fillRect(5, 5, 3, 3, 0x1111);

    const rects = fb.getDirtyRects();
    try testing.expectEqual(@as(usize, 1), rects.len);
    try testing.expectEqual(@as(u16, 5), rects[0].x);
    try testing.expectEqual(@as(u16, 5), rects[0].y);
    try testing.expectEqual(@as(u16, 3), rects[0].w);
    try testing.expectEqual(@as(u16, 3), rects[0].h);
}

test "drawRect draws outline" {
    var fb = TestFB.init(0);
    fb.drawRect(2, 2, 8, 8, 0xFFFF, 1);

    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(2, 2));
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(9, 2));
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(2, 9));
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(2, 5));
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(9, 5));
    try testing.expectEqual(@as(u16, 0), fb.getPixel(5, 5));
}

test "hline and vline" {
    var fb = TestFB.init(0);
    fb.hline(0, 8, 16, 0xAAAA);
    fb.vline(8, 0, 16, 0xBBBB);

    try testing.expectEqual(@as(u16, 0xAAAA), fb.getPixel(0, 8));
    try testing.expectEqual(@as(u16, 0xAAAA), fb.getPixel(15, 8));
    try testing.expectEqual(@as(u16, 0xBBBB), fb.getPixel(8, 0));
    try testing.expectEqual(@as(u16, 0xBBBB), fb.getPixel(8, 15));
    try testing.expectEqual(@as(u16, 0xBBBB), fb.getPixel(8, 8));
}

test "clear marks all dirty" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    fb.clear(0x1234);

    const rects = fb.getDirtyRects();
    try testing.expectEqual(@as(usize, 1), rects.len);
    try testing.expectEqual(@as(u16, 0), rects[0].x);
    try testing.expectEqual(@as(u16, 0), rects[0].y);
    try testing.expectEqual(@as(u16, 16), rects[0].w);
    try testing.expectEqual(@as(u16, 16), rects[0].h);
}

test "flush sends full buffer to display" {
    var fb = TestFB.init(0);
    fb.setPixel(5, 5, 0xABCD);

    const MockDisplay = struct {
        called: bool = false,
        data_len: usize = 0,
        x: u16 = 0,
        y: u16 = 0,
        w: u16 = 0,
        h: u16 = 0,

        pub fn drawBitmap(self: *@This(), x: u16, y: u16, w: u16, h: u16, data: []const u16) !void {
            self.called = true;
            self.x = x;
            self.y = y;
            self.w = w;
            self.h = h;
            self.data_len = data.len;
        }
    };

    var display = MockDisplay{};
    try fb.flush(&display);

    try testing.expect(display.called);
    try testing.expectEqual(@as(u16, 0), display.x);
    try testing.expectEqual(@as(u16, 0), display.y);
    try testing.expectEqual(@as(u16, 16), display.w);
    try testing.expectEqual(@as(u16, 16), display.h);
    try testing.expectEqual(@as(usize, 256), display.data_len);
}
