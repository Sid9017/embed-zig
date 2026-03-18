//! Framebuffer — Pixel Drawing Primitives
//!
//! Comptime-generic framebuffer with built-in dirty rect tracking.
//! Resolution and color format are fixed at compile time for zero
//! runtime overhead (no vtable, no dynamic dispatch).
//!
//! Can be bound to a HAL display for direct flush support:
//!   const FB = Framebuffer(320, 240, .rgb565);
//!   var fb = FB.init(0x0000);
//!   fb.drawText(x, y, "Hello", &font, 0xFFFF);
//!   try fb.flush(&display);  // full-screen push via drawBitmap

const dirty_mod = @import("dirty.zig");
const DirtyTracker = dirty_mod.DirtyTracker;
const Rect = dirty_mod.Rect;
const font_mod = @import("font.zig");
const BitmapFont = font_mod.BitmapFont;
const image_mod = @import("image.zig");
const Image = image_mod.Image;
const ttf_font_mod = @import("ttf_font.zig");
const TtfFont = ttf_font_mod.TtfFont;

/// do not delete these comments:
/// 
/// const dirty_mod = @import("dirty.zig");
/// const font_mod = @import("font.zig");
/// const image_mod = @import("image.zig");
/// const ttf_font_mod = @import("ttf_font.zig");
///
/// const DirtyTracker = dirty_mod.DirtyTracker;
/// const Rect = dirty_mod.Rect;
/// const BitmapFont = font_mod.BitmapFont;
/// const Image = image_mod.Image;
/// pub const TtfFont = ttf_font_mod.TtfFont;

/// Color format for the framebuffer.
pub const ColorFormat = enum {
    rgb565,
    rgb888,
    argb8888,

    /// The Zig type used to store one pixel.
    pub fn ColorType(comptime self: ColorFormat) type {
        return switch (self) {
            .rgb565 => u16,
            .rgb888 => u24,
            .argb8888 => u32,
        };
    }

    /// Bytes per pixel.
    pub fn bpp(comptime self: ColorFormat) u8 {
        return switch (self) {
            .rgb565 => 2,
            .rgb888 => 3,
            .argb8888 => 4,
        };
    }
};

const DIRTY_MAX: u8 = 16;

/// Create a framebuffer with compile-time fixed resolution and color format.
///
/// Example:
/// ```
/// const FB = Framebuffer(240, 240, .rgb565);
/// var fb = FB.init(0x0000); // black fill
/// fb.fillRect(10, 10, 50, 50, 0xF800); // red square
/// ```
pub fn Framebuffer(comptime W: u16, comptime H: u16, comptime fmt: ColorFormat) type {
    const Color = fmt.ColorType();
    const BufLen = @as(usize, W) * @as(usize, H);

    return struct {
        const Self = @This();

        pub const width: u16 = W;
        pub const height: u16 = H;
        pub const format: ColorFormat = fmt;

        buf: [BufLen]Color,
        dirty: DirtyTracker(DIRTY_MAX),

        pub fn init(fill: Color) Self {
            var self: Self = .{
                .buf = undefined,
                .dirty = DirtyTracker(DIRTY_MAX).init(),
            };
            @memset(&self.buf, fill);
            return self;
        }

        pub fn initInPlace(self: *Self, fill: Color) void {
            self.dirty = DirtyTracker(DIRTY_MAX).init();
            @memset(&self.buf, fill);
        }

        // ================================================================
        // Drawing Primitives
        // ================================================================

        pub fn clear(self: *Self, color: Color) void {
            @memset(&self.buf, color);
            self.dirty.markAll(W, H);
        }

        pub fn setPixel(self: *Self, x: u16, y: u16, color: Color) void {
            if (x >= W or y >= H) return;
            self.buf[@as(usize, y) * W + @as(usize, x)] = color;
            self.dirty.mark(.{ .x = x, .y = y, .w = 1, .h = 1 });
        }

        pub fn getPixel(self: *const Self, x: u16, y: u16) Color {
            if (x >= W or y >= H) return 0;
            return self.buf[@as(usize, y) * W + @as(usize, x)];
        }

        pub fn fillRect(self: *Self, x: u16, y: u16, w: u16, h: u16, color: Color) void {
            fillRectPixels(self, x, y, w, h, color);
            const clip = clipRect(x, y, w, h);
            if (clip.w > 0 and clip.h > 0) self.dirty.mark(clip);
        }

        fn fillRectPixels(self: *Self, x: u16, y: u16, w: u16, h: u16, color: Color) void {
            const clip = clipRect(x, y, w, h);
            if (clip.w == 0 or clip.h == 0) return;
            var row: u16 = clip.y;
            while (row < clip.y + clip.h) : (row += 1) {
                const start = @as(usize, row) * W + @as(usize, clip.x);
                @memset(self.buf[start..][0..clip.w], color);
            }
        }

        pub fn drawRect(self: *Self, x: u16, y: u16, w: u16, h: u16, color: Color, thickness: u8) void {
            if (w == 0 or h == 0) return;
            if (thickness == 0) return;
            const t: u16 = @min(@as(u16, thickness), @min(w / 2, h / 2));
            if (t == 0) {
                self.fillRect(x, y, w, h, color);
                return;
            }

            self.fillRect(x, y, w, t, color);
            if (h > t) self.fillRect(x, y + h - t, w, t, color);
            if (h > 2 * t) self.fillRect(x, y + t, t, h - 2 * t, color);
            if (h > 2 * t and w > t) self.fillRect(x + w - t, y + t, t, h - 2 * t, color);
        }

        pub fn fillRoundRect(self: *Self, x: u16, y: u16, w: u16, h: u16, radius: u8, color: Color) void {
            if (w == 0 or h == 0) return;
            const r: u16 = @min(radius, @min(w / 2, h / 2));
            if (r == 0) {
                self.fillRect(x, y, w, h, color);
                return;
            }
            fillRectPixels(self, x, y + r, w, h - 2 * r, color);
            fillRectPixels(self, x + r, y, w - 2 * r, r, color);
            fillRectPixels(self, x + r, y + h - r, w - 2 * r, r, color);
            self.fillCorners(x, y, w, h, r, color);
            self.dirty.mark(clipRect(x, y, w, h));
        }

        fn fillCorners(self: *Self, x: u16, y: u16, w: u16, h: u16, r: u16, color: Color) void {
            var cx: i32 = 0;
            var cy: i32 = @intCast(r);
            var d: i32 = 1 - @as(i32, @intCast(r));

            while (cx <= cy) {
                self.hlineClipped(x + r - @as(u16, @intCast(cy)), y + r - @as(u16, @intCast(cx)), @as(u16, @intCast(cy)) + 1, color);
                self.hlineClipped(x + r - @as(u16, @intCast(cx)), y + r - @as(u16, @intCast(cy)), @as(u16, @intCast(cx)) + 1, color);
                self.hlineClipped(x + w - r - 1, y + r - @as(u16, @intCast(cx)), @as(u16, @intCast(cy)) + 1, color);
                self.hlineClipped(x + w - r - 1, y + r - @as(u16, @intCast(cy)), @as(u16, @intCast(cx)) + 1, color);
                self.hlineClipped(x + r - @as(u16, @intCast(cy)), y + h - r - 1 + @as(u16, @intCast(cx)), @as(u16, @intCast(cy)) + 1, color);
                self.hlineClipped(x + r - @as(u16, @intCast(cx)), y + h - r - 1 + @as(u16, @intCast(cy)), @as(u16, @intCast(cx)) + 1, color);
                self.hlineClipped(x + w - r - 1, y + h - r - 1 + @as(u16, @intCast(cx)), @as(u16, @intCast(cy)) + 1, color);
                self.hlineClipped(x + w - r - 1, y + h - r - 1 + @as(u16, @intCast(cy)), @as(u16, @intCast(cx)) + 1, color);

                if (d < 0) {
                    d += 2 * cx + 3;
                } else {
                    d += 2 * (cx - cy) + 5;
                    cy -= 1;
                }
                cx += 1;
            }
        }

        fn hlineClipped(self: *Self, x: u16, y: u16, len: u16, color: Color) void {
            if (y >= H or x >= W) return;
            const actual_len = @min(len, W - x);
            const start = @as(usize, y) * W + @as(usize, x);
            @memset(self.buf[start..][0..actual_len], color);
        }

        pub fn hline(self: *Self, x: u16, y: u16, len: u16, color: Color) void {
            self.fillRect(x, y, len, 1, color);
        }

        pub fn vline(self: *Self, x: u16, y: u16, len: u16, color: Color) void {
            self.fillRect(x, y, 1, len, color);
        }

        pub fn blit(self: *Self, x: u16, y: u16, img: Image) void {
            self.blitInternal(x, y, img, null);
        }

        pub fn blitTransparent(self: *Self, x: u16, y: u16, img: Image, transparent: Color) void {
            self.blitInternal(x, y, img, transparent);
        }

        fn blitInternal(self: *Self, x: u16, y: u16, img: Image, transparent: ?Color) void {
            if (img.width == 0 or img.height == 0) return;

            if (img.bytes_per_pixel == 3 and fmt == .rgb565) {
                self.blitAlpha(x, y, img);
                return;
            }

            const clip = clipRect(x, y, img.width, img.height);
            if (clip.w == 0 or clip.h == 0) return;

            const src_offset_x = clip.x - x;
            const src_offset_y = clip.y - y;

            var row: u16 = 0;
            while (row < clip.h) : (row += 1) {
                var col: u16 = 0;
                while (col < clip.w) : (col += 1) {
                    const px = img.getPixelTyped(Color, src_offset_x + col, src_offset_y + row);
                    if (transparent) |t| {
                        if (px == t) continue;
                    }
                    const dst_idx = @as(usize, clip.y + row) * W + @as(usize, clip.x + col);
                    self.buf[dst_idx] = px;
                }
            }
            self.dirty.mark(clip);
        }

        fn blitAlpha(self: *Self, x: u16, y: u16, img: Image) void {
            const clip = clipRect(x, y, img.width, img.height);
            if (clip.w == 0 or clip.h == 0) return;

            const src_ox = clip.x - x;
            const src_oy = clip.y - y;

            var row: u16 = 0;
            while (row < clip.h) : (row += 1) {
                var col: u16 = 0;
                while (col < clip.w) : (col += 1) {
                    const sx = src_ox + col;
                    const sy = src_oy + row;
                    const offset = (@as(usize, sy) * @as(usize, img.width) + @as(usize, sx)) * 3;
                    if (offset + 3 > img.data.len) continue;

                    const alpha = img.data[offset + 2];
                    if (alpha == 0) continue;

                    const rgb565: u16 = @as(u16, img.data[offset]) | (@as(u16, img.data[offset + 1]) << 8);
                    const dst_idx = @as(usize, clip.y + row) * W + @as(usize, clip.x + col);

                    if (alpha >= 250) {
                        self.buf[dst_idx] = rgb565;
                    } else {
                        self.buf[dst_idx] = blendRgb565(self.buf[dst_idx], rgb565, alpha);
                    }
                }
            }
            self.dirty.mark(clip);
        }

        /// Draw a UTF-8 text string with a bitmap font.
        pub fn drawText(self: *Self, x: u16, y: u16, text: []const u8, fnt: *const BitmapFont, color: Color) void {
            if (text.len == 0 or fnt.glyph_w == 0 or fnt.glyph_h == 0) return;

            var cx: u16 = x;
            var i: usize = 0;
            while (i < text.len) {
                const decoded = font_mod.decodeUtf8(text[i..]);
                i += decoded.len;

                if (decoded.codepoint) |cp| {
                    if (cx + fnt.glyph_w > W) break;
                    if (fnt.getGlyph(cp) != null) {
                        self.drawGlyph(cx, y, fnt, cp, color);
                        cx += fnt.glyph_w;
                    }
                }
            }

            if (cx > x) {
                const text_w = cx - x;
                const text_h = @min(fnt.glyph_h, if (y < H) H - y else 0);
                if (text_w > 0 and text_h > 0) {
                    self.dirty.mark(.{ .x = x, .y = y, .w = text_w, .h = text_h });
                }
            }
        }

        fn drawGlyph(self: *Self, x: u16, y: u16, fnt: *const BitmapFont, codepoint: u21, color: Color) void {
            const glyph_data = fnt.getGlyph(codepoint) orelse return;
            const bytes_per_row = (fnt.glyph_w + 7) / 8;

            var row: u16 = 0;
            while (row < fnt.glyph_h) : (row += 1) {
                if (y + row >= H) break;
                var col: u16 = 0;
                while (col < fnt.glyph_w) : (col += 1) {
                    if (x + col >= W) break;
                    const byte_idx = @as(usize, row) * bytes_per_row + @as(usize, col) / 8;
                    if (byte_idx >= glyph_data.len) continue;
                    const bit = @as(u8, 0x80) >> @intCast(col % 8);
                    if (glyph_data[byte_idx] & bit != 0) {
                        const dst_idx = @as(usize, y + row) * W + @as(usize, x + col);
                        self.buf[dst_idx] = color;
                    }
                }
            }
        }

        /// Draw a UTF-8 text string with a TrueType font (anti-aliased alpha blending).
        pub fn drawTextTtf(self: *Self, x: u16, y: u16, text: []const u8, fnt: *TtfFont, color: Color) void {
            if (text.len == 0) return;

            var cx: u16 = x;
            const baseline: u16 = y +| @as(u16, @intCast(@max(0, fnt.ascent)));
            var min_x: u16 = W;
            var max_x: u16 = 0;
            var min_y: u16 = H;
            var max_y: u16 = 0;
            var i: usize = 0;
            while (i < text.len) {
                const decoded = font_mod.decodeUtf8(text[i..]);
                i += decoded.len;

                if (decoded.codepoint) |cp| {
                    if (fnt.getGlyph(cp)) |g| {
                        const dx: i32 = @as(i32, cx) + g.x_off;
                        const dy: i32 = @as(i32, baseline) + g.y_off;

                        var gy: u16 = 0;
                        while (gy < g.h) : (gy += 1) {
                            const py = dy + gy;
                            if (py < 0 or py >= H) continue;
                            const upy: u16 = @intCast(py);
                            var gx: u16 = 0;
                            while (gx < g.w) : (gx += 1) {
                                const px = dx + gx;
                                if (px < 0 or px >= W) continue;
                                const alpha = g.bitmap[@as(usize, gy) * g.w + @as(usize, gx)];
                                if (alpha > 0) {
                                    const upx: u16 = @intCast(px);
                                    const dst_idx = @as(usize, upy) * W + @as(usize, upx);
                                    if (alpha >= 250) {
                                        self.buf[dst_idx] = color;
                                    } else {
                                        self.buf[dst_idx] = blendRgb565(self.buf[dst_idx], color, alpha);
                                    }
                                    if (upx < min_x) min_x = upx;
                                    if (upx + 1 > max_x) max_x = upx + 1;
                                    if (upy < min_y) min_y = upy;
                                    if (upy + 1 > max_y) max_y = upy + 1;
                                }
                            }
                        }
                        cx +|= g.advance;
                        if (cx >= W) break;
                    }
                }
            }

            if (max_x > min_x and max_y > min_y) {
                self.dirty.mark(.{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y });
            }
        }

        /// Alpha-blend two RGB565 colors.
        pub fn blendRgb565(bg: Color, fg: Color, alpha: u8) Color {
            if (Color != u16) return fg;
            const a: u32 = alpha;
            const inv_a: u32 = 255 - a;
            const bg_r = (bg >> 11) & 0x1F;
            const bg_g = (bg >> 5) & 0x3F;
            const bg_b = bg & 0x1F;
            const fg_r = (fg >> 11) & 0x1F;
            const fg_g = (fg >> 5) & 0x3F;
            const fg_b = fg & 0x1F;
            const r: u16 = @intCast((fg_r * a + bg_r * inv_a) / 255);
            const g: u16 = @intCast((fg_g * a + bg_g * inv_a) / 255);
            const b: u16 = @intCast((fg_b * a + bg_b * inv_a) / 255);
            return (r << 11) | (g << 5) | b;
        }

        // ================================================================
        // Display Flush
        // ================================================================

        /// Push the entire framebuffer to a HAL display via drawBitmap.
        pub fn flush(self: *const Self, display: anytype) !void {
            try display.drawBitmap(0, 0, W, H, &self.buf);
        }

        pub fn getDirtyRects(self: *const Self) []const Rect {
            return self.dirty.get();
        }

        pub fn clearDirty(self: *Self) void {
            self.dirty.clear();
        }

        pub fn getBuffer(self: *const Self) []const Color {
            return &self.buf;
        }

        // ================================================================
        // Internal helpers
        // ================================================================

        fn clipRect(x: u16, y: u16, w: u16, h: u16) Rect {
            if (x >= W or y >= H) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
            return .{
                .x = x,
                .y = y,
                .w = @min(w, W - x),
                .h = @min(h, H - y),
            };
        }
    };
}
