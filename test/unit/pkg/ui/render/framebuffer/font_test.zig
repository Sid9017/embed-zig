const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const fb_font = embed.pkg.ui.render.fb_font;

// ============================================================================
// Tests
// ============================================================================

const test_font_data = [_]u8{
    // A
    0x60, 0x90, 0xF0, 0x90,
    // B
    0xE0, 0x90, 0xE0, 0xE0,
    // C
    0x60, 0x80, 0x80, 0x60,
};

fn testLookup(cp: u21) ?u32 {
    if (cp >= 'A' and cp <= 'C') return @intCast(cp - 'A');
    return null;
}

const test_font = fb_font.BitmapFont{
    .glyph_w = 4,
    .glyph_h = 4,
    .data = &test_font_data,
    .lookup = &testLookup,
};

test "BitmapFont.glyphSize" {
    try testing.expectEqual(@as(usize, 4), test_font.glyphSize());
}

test "BitmapFont.getGlyph returns correct data" {
    const glyph_a = test_font.getGlyph('A').?;
    try testing.expectEqual(@as(usize, 4), glyph_a.len);
    try testing.expectEqual(@as(u8, 0x60), glyph_a[0]);
    try testing.expectEqual(@as(u8, 0x90), glyph_a[1]);

    const glyph_c = test_font.getGlyph('C').?;
    try testing.expectEqual(@as(u8, 0x60), glyph_c[0]);
    try testing.expectEqual(@as(u8, 0x80), glyph_c[1]);
}

test "BitmapFont.getGlyph returns null for unknown" {
    try testing.expectEqual(@as(?[]const u8, null), test_font.getGlyph('Z'));
    try testing.expectEqual(@as(?[]const u8, null), test_font.getGlyph(0x4E2D));
}

test "BitmapFont.textWidth" {
    try testing.expectEqual(@as(u16, 12), test_font.textWidth("ABC"));
    try testing.expectEqual(@as(u16, 4), test_font.textWidth("A"));
    try testing.expectEqual(@as(u16, 4), test_font.textWidth("AZ"));
    try testing.expectEqual(@as(u16, 0), test_font.textWidth(""));
    try testing.expectEqual(@as(u16, 0), test_font.textWidth("XYZ"));
}

test "asciiLookup: printable ASCII" {
    const lookup = fb_font.asciiLookup(32, 95);
    try testing.expectEqual(@as(?u32, 0), lookup(' '));
    try testing.expectEqual(@as(?u32, 33), lookup('A'));
    try testing.expectEqual(@as(?u32, 94), lookup('~'));
    try testing.expectEqual(@as(?u32, null), lookup(0x1F));
    try testing.expectEqual(@as(?u32, null), lookup(0x7F));
}

test "decodeUtf8: ASCII" {
    const r = fb_font.decodeUtf8("Hello");
    try testing.expectEqual(@as(?u21, 'H'), r.codepoint);
    try testing.expectEqual(@as(usize, 1), r.len);
}

test "decodeUtf8: 2-byte (Latin)" {
    const r = fb_font.decodeUtf8("\xC3\xA9");
    try testing.expectEqual(@as(?u21, 0xE9), r.codepoint);
    try testing.expectEqual(@as(usize, 2), r.len);
}

test "decodeUtf8: 3-byte (CJK)" {
    const r = fb_font.decodeUtf8("\xE4\xB8\xAD");
    try testing.expectEqual(@as(?u21, 0x4E2D), r.codepoint);
    try testing.expectEqual(@as(usize, 3), r.len);
}

test "decodeUtf8: 4-byte (emoji)" {
    const r = fb_font.decodeUtf8("\xF0\x9F\x98\x80");
    try testing.expectEqual(@as(?u21, 0x1F600), r.codepoint);
    try testing.expectEqual(@as(usize, 4), r.len);
}

test "decodeUtf8: invalid byte" {
    const r = fb_font.decodeUtf8("\xFF\x00");
    try testing.expectEqual(@as(?u21, null), r.codepoint);
    try testing.expectEqual(@as(usize, 1), r.len);
}

test "decodeUtf8: empty" {
    const r = fb_font.decodeUtf8("");
    try testing.expectEqual(@as(?u21, null), r.codepoint);
    try testing.expectEqual(@as(usize, 0), r.len);
}
