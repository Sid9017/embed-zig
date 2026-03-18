const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const Font = embed.pkg.ui.font;

fn TestBin(
    comptime glyph_w: u8,
    comptime glyph_h: u8,
    comptime codepoints: []const u32,
) type {
    const hdr_size = 4;
    const char_count: u16 = @intCast(codepoints.len);
    const bytes_per_row = (@as(usize, glyph_w) + 7) / 8;
    const glyph_size = bytes_per_row * @as(usize, glyph_h);
    const bitmap_size = @as(usize, char_count) * glyph_size;
    const total = hdr_size + @as(usize, char_count) * 4 + bitmap_size;

    return struct {
        pub const data: [total]u8 = blk: {
            var buf: [total]u8 = undefined;
            buf[0] = glyph_w;
            buf[1] = glyph_h;
            buf[2] = @truncate(char_count);
            buf[3] = @truncate(char_count >> 8);

            for (codepoints, 0..) |cp, i| {
                const off = hdr_size + i * 4;
                buf[off] = @truncate(cp);
                buf[off + 1] = @truncate(cp >> 8);
                buf[off + 2] = @truncate(cp >> 16);
                buf[off + 3] = @truncate(cp >> 24);
            }

            for (hdr_size + @as(usize, char_count) * 4..total) |j| {
                buf[j] = @truncate(j & 0xFF);
            }

            break :blk buf;
        };
    };
}

test "fromBinary: parse valid 3-char font" {
    const font = comptime Font.fromBinary(&TestBin(8, 8, &.{ 'A', 'B', 'C' }).data);

    try testing.expectEqual(@as(u8, 8), font.glyph_w);
    try testing.expectEqual(@as(u8, 8), font.glyph_h);

    try testing.expectEqual(@as(?u32, 0), font.lookup('A'));
    try testing.expectEqual(@as(?u32, 1), font.lookup('B'));
    try testing.expectEqual(@as(?u32, 2), font.lookup('C'));
    try testing.expectEqual(@as(?u32, null), font.lookup('D'));
    try testing.expectEqual(@as(?u32, null), font.lookup(0x4E2D));
}

test "fromBinary: CJK codepoints" {
    const font = comptime Font.fromBinary(&TestBin(16, 16, &.{ 0x4E2D, 0x6587, 0x8BD5 }).data);

    try testing.expectEqual(@as(?u32, 0), font.lookup(0x4E2D));
    try testing.expectEqual(@as(?u32, 1), font.lookup(0x6587));
    try testing.expectEqual(@as(?u32, 2), font.lookup(0x8BD5));
    try testing.expectEqual(@as(?u32, null), font.lookup('A'));
}

test "fromBinary: single char" {
    const font = comptime Font.fromBinary(&TestBin(4, 4, &.{'X'}).data);

    try testing.expectEqual(@as(?u32, 0), font.lookup('X'));
    try testing.expectEqual(@as(?u32, null), font.lookup('Y'));
}

test "fromBinary: glyph data accessible" {
    const font = comptime Font.fromBinary(&TestBin(8, 4, &.{ 'A', 'B' }).data);

    const glyph_a = font.getGlyph('A');
    try testing.expect(glyph_a != null);
    try testing.expectEqual(@as(usize, 4), glyph_a.?.len);

    const glyph_b = font.getGlyph('B');
    try testing.expect(glyph_b != null);
    try testing.expectEqual(@as(usize, 4), glyph_b.?.len);
}

test "fromBinary: textWidth works" {
    const font = comptime Font.fromBinary(&TestBin(8, 8, &.{ 'A', 'B', 'C' }).data);

    try testing.expectEqual(@as(u16, 24), font.textWidth("ABC"));
    try testing.expectEqual(@as(u16, 8), font.textWidth("AZ"));
    try testing.expectEqual(@as(u16, 0), font.textWidth("XYZ"));
}

test "validate: accepts valid data" {
    try Font.validate(&TestBin(8, 8, &.{ 'A', 'B', 'C' }).data);
}

test "validate: rejects too-short data" {
    try testing.expectError(error.TooShort, Font.validate(""));
    try testing.expectError(error.TooShort, Font.validate(&[_]u8{ 8, 8, 1 }));
}

test "validate: rejects zero dimension" {
    try testing.expectError(error.ZeroDimension, Font.validate(&[_]u8{ 0, 8, 0, 0 }));
    try testing.expectError(error.ZeroDimension, Font.validate(&[_]u8{ 8, 0, 0, 0 }));
}

test "validate: rejects truncated codepoints" {
    try testing.expectError(error.TruncatedCodepoints, Font.validate(&[_]u8{ 8, 8, 2, 0, 'A', 0, 0, 0 }));
}

test "validate: rejects truncated bitmap" {
    var buf = [_]u8{0} ** 12;
    buf[0] = 8;
    buf[1] = 8;
    buf[2] = 1;
    buf[3] = 0;
    buf[4] = 'A';
    try testing.expectError(error.TruncatedBitmapData, Font.validate(&buf));
}

test "lookupCodepoint: runtime binary search" {
    const table = [_]u8{
        'A', 0, 0, 0,
        'B', 0, 0, 0,
        'C', 0, 0, 0,
    };
    try testing.expectEqual(@as(?u32, 0), Font.lookupCodepoint(&table, 3, 'A'));
    try testing.expectEqual(@as(?u32, 1), Font.lookupCodepoint(&table, 3, 'B'));
    try testing.expectEqual(@as(?u32, 2), Font.lookupCodepoint(&table, 3, 'C'));
    try testing.expectEqual(@as(?u32, null), Font.lookupCodepoint(&table, 3, 'D'));
}
