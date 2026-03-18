//! TtfFont — Runtime TrueType font renderer via stb_truetype
//!
//! Renders glyphs lazily from TTF font data.
//! Supports any Unicode codepoint at any size with 8-bit alpha anti-aliasing.
//!
//! Platform compatibility: requires `<math.h>` and `<stdlib.h>`.
//! Works on macOS/Linux (native libc), ESP32 (newlib), WASM (wasi-libc).

const embed = @import("../../../../mod.zig");
const font_mod = @import("font.zig");
const c = embed.third_party.stb_truetype.c;

pub const Glyph = struct {
    bitmap: [*]const u8,
    w: u16,
    h: u16,
    x_off: i16,
    y_off: i16,
    advance: u16,
};

const CACHE_SIZE = 128;
const MAX_GLYPH_DIM = 48;

const CacheEntry = struct {
    codepoint: u21 = 0,
    size_x10: u16 = 0,
    bitmap_buf: [MAX_GLYPH_DIM * MAX_GLYPH_DIM]u8 = undefined,
    glyph: Glyph = undefined,
    valid: bool = false,
};

pub const TtfFont = struct {
    const Self = @This();

    info: c.stbtt_fontinfo,
    scale: f32,
    ascent: i32,
    descent: i32,
    line_gap: i32,
    size: f32,
    cache: [CACHE_SIZE]CacheEntry,

    pub fn init(ttf_data: []const u8, pixel_size: f32) ?Self {
        var self: Self = undefined;
        if (!self.initCommon(ttf_data, pixel_size)) return null;
        return self;
    }

    /// In-place init for heap-allocated TtfFont (avoids large stack copy).
    pub fn initInPlace(self: *Self, ttf_data: []const u8, pixel_size: f32) bool {
        return self.initCommon(ttf_data, pixel_size);
    }

    fn initCommon(self: *Self, ttf_data: []const u8, pixel_size: f32) bool {
        self.size = pixel_size;
        @memset(&self.cache, CacheEntry{});

        if (c.stbtt_InitFont(&self.info, ttf_data.ptr, 0) == 0) {
            return false;
        }

        self.scale = c.stbtt_ScaleForPixelHeight(&self.info, pixel_size);

        var asc: c_int = 0;
        var desc: c_int = 0;
        var gap: c_int = 0;
        c.stbtt_GetFontVMetrics(&self.info, &asc, &desc, &gap);
        self.ascent = @intFromFloat(@as(f32, @floatFromInt(asc)) * self.scale);
        self.descent = @intFromFloat(@as(f32, @floatFromInt(desc)) * self.scale);
        self.line_gap = @intFromFloat(@as(f32, @floatFromInt(gap)) * self.scale);

        return true;
    }

    pub fn lineHeight(self: *const Self) u16 {
        return @intCast(self.ascent - self.descent + self.line_gap);
    }

    pub fn getGlyph(self: *Self, codepoint: u21) ?Glyph {
        const size_x10: u16 = @intFromFloat(self.size * 10);

        const slot = @as(usize, codepoint) % CACHE_SIZE;
        if (self.cache[slot].valid and
            self.cache[slot].codepoint == codepoint and
            self.cache[slot].size_x10 == size_x10)
        {
            return self.cache[slot].glyph;
        }

        var adv: c_int = 0;
        var lsb: c_int = 0;
        c.stbtt_GetCodepointHMetrics(&self.info, @intCast(codepoint), &adv, &lsb);
        const advance: u16 = @intFromFloat(@as(f32, @floatFromInt(adv)) * self.scale);

        var w: c_int = 0;
        var h: c_int = 0;
        var x_off: c_int = 0;
        var y_off: c_int = 0;

        const bitmap = c.stbtt_GetCodepointBitmap(
            &self.info,
            0,
            self.scale,
            @intCast(codepoint),
            &w,
            &h,
            &x_off,
            &y_off,
        );
        defer if (bitmap != null) c.stbtt_FreeBitmap(bitmap, null);

        const uw: u16 = @intCast(w);
        const uh: u16 = @intCast(h);
        const copy_size = @as(usize, uw) * @as(usize, uh);

        if (copy_size <= self.cache[slot].bitmap_buf.len) {
            if (bitmap != null and copy_size > 0) {
                @memcpy(self.cache[slot].bitmap_buf[0..copy_size], bitmap[0..copy_size]);
            }
            self.cache[slot].glyph = .{
                .bitmap = &self.cache[slot].bitmap_buf,
                .w = uw,
                .h = uh,
                .x_off = @intCast(x_off),
                .y_off = @intCast(y_off),
                .advance = advance,
            };
            self.cache[slot].codepoint = codepoint;
            self.cache[slot].size_x10 = size_x10;
            self.cache[slot].valid = true;
            return self.cache[slot].glyph;
        }

        return null;
    }

    pub fn textWidth(self: *Self, text: []const u8) u16 {
        var width: u16 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const decoded = font_mod.decodeUtf8(text[i..]);
            i += decoded.len;
            if (decoded.codepoint) |cp| {
                if (self.getGlyph(cp)) |g| {
                    width += g.advance;
                }
            }
        }
        return width;
    }
};
