//! Font - Binary Font Loader + BitmapFont Re-exports
//!
//! Parses `.bin` font files (produced by `ttf2bitmapfont`) into `BitmapFont`
//! descriptors. Also re-exports the core bitmap font helpers from the
//! framebuffer font module.

const fb_font = @import("../framebuffer/font.zig");

pub const BitmapFont = fb_font.BitmapFont;
pub const asciiLookup = fb_font.asciiLookup;
pub const decodeUtf8 = fb_font.decodeUtf8;

pub const Error = error{
    TooShort,
    ZeroDimension,
    TruncatedCodepoints,
    TruncatedBitmapData,
};

const header_size = 4;

/// Parse a `.bin` font file into a BitmapFont.
pub fn fromBinary(comptime data: []const u8) BitmapFont {
    comptime {
        if (data.len < header_size) @compileError("font binary too short");

        const glyph_w = data[0];
        const glyph_h = data[1];
        if (glyph_w == 0 or glyph_h == 0) @compileError("font has zero dimension");

        const char_count: u16 = @as(u16, data[3]) << 8 | data[2];
        const cp_table_end = header_size + @as(usize, char_count) * 4;

        if (data.len < cp_table_end) @compileError("font binary truncated: codepoint table incomplete");

        const bytes_per_row = (@as(usize, glyph_w) + 7) / 8;
        const glyph_size = bytes_per_row * @as(usize, glyph_h);
        const bitmap_size = @as(usize, char_count) * glyph_size;

        if (data.len < cp_table_end + bitmap_size) @compileError("font binary truncated: bitmap data incomplete");

        const cp_table = data[header_size..cp_table_end];
        const bitmap_data = data[cp_table_end..][0..bitmap_size];

        const S = struct {
            fn lookup(cp: u21) ?u32 {
                return binarySearchComptime(cp_table, char_count, cp);
            }
        };

        return BitmapFont{
            .glyph_w = glyph_w,
            .glyph_h = glyph_h,
            .data = bitmap_data,
            .lookup = &S.lookup,
        };
    }
}

/// Validate a `.bin` font at runtime without constructing a BitmapFont.
pub fn validate(data: []const u8) Error!void {
    if (data.len < header_size) return error.TooShort;

    const glyph_w = data[0];
    const glyph_h = data[1];
    if (glyph_w == 0 or glyph_h == 0) return error.ZeroDimension;

    const char_count: u16 = @as(u16, data[3]) << 8 | data[2];
    const cp_table_end = header_size + @as(usize, char_count) * 4;

    if (data.len < cp_table_end) return error.TruncatedCodepoints;

    const bytes_per_row = (@as(usize, glyph_w) + 7) / 8;
    const glyph_size = bytes_per_row * @as(usize, glyph_h);
    const bitmap_size = @as(usize, char_count) * glyph_size;

    if (data.len < cp_table_end + bitmap_size) return error.TruncatedBitmapData;
}

/// Runtime binary search over a codepoint table (for dynamic font loading).
pub fn lookupCodepoint(cp_table: []const u8, char_count: u16, target: u21) ?u32 {
    return binarySearchRuntime(cp_table, char_count, target);
}

fn binarySearchComptime(comptime table: []const u8, comptime count: u16, target: u21) ?u32 {
    const target32: u32 = target;
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const val = readCp(table, mid);
        if (val == target32) return @intCast(mid);
        if (val < target32) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return null;
}

fn binarySearchRuntime(table: []const u8, count: u16, target: u21) ?u32 {
    const target32: u32 = target;
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const val = readCp(table, mid);
        if (val == target32) return @intCast(mid);
        if (val < target32) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return null;
}

inline fn readCp(table: []const u8, idx: usize) u32 {
    const off = idx * 4;
    return @as(u32, table[off]) |
        (@as(u32, table[off + 1]) << 8) |
        (@as(u32, table[off + 2]) << 16) |
        (@as(u32, table[off + 3]) << 24);
}

const std = @import("std");
const testing = std.testing;

pub fn TestBin(
    comptime glyph_w: u8,
    comptime glyph_h: u8,
    comptime codepoints: []const u32,
) type {
    const char_count: u16 = @intCast(codepoints.len);
    const bytes_per_row = (@as(usize, glyph_w) + 7) / 8;
    const glyph_size = bytes_per_row * @as(usize, glyph_h);
    const bitmap_size = @as(usize, char_count) * glyph_size;
    const total = header_size + @as(usize, char_count) * 4 + bitmap_size;

    return struct {
        pub const data: [total]u8 = blk: {
            var buf: [total]u8 = undefined;
            buf[0] = glyph_w;
            buf[1] = glyph_h;
            buf[2] = @truncate(char_count);
            buf[3] = @truncate(char_count >> 8);

            for (codepoints, 0..) |cp, i| {
                const off = header_size + i * 4;
                buf[off] = @truncate(cp);
                buf[off + 1] = @truncate(cp >> 8);
                buf[off + 2] = @truncate(cp >> 16);
                buf[off + 3] = @truncate(cp >> 24);
            }

            for (header_size + @as(usize, char_count) * 4..total) |j| {
                buf[j] = @truncate(j & 0xFF);
            }

            break :blk buf;
        };
    };
}
