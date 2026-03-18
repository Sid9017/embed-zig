const std = @import("std");
const testing = std.testing;
const Image = @import("embed").pkg.ui.render.image.Image;

// ============================================================================
// Tests
// ============================================================================

test "Image.getPixel RGB565" {
    const data = [_]u8{
        0x34, 0x12, // (0,0) = 0x1234
        0x78, 0x56, // (1,0) = 0x5678
        0xBC, 0x9A, // (0,1) = 0x9ABC
        0xF0, 0xDE, // (1,1) = 0xDEF0
    };

    const img = Image{
        .width = 2,
        .height = 2,
        .data = &data,
        .bytes_per_pixel = 2,
    };

    try testing.expectEqual(@as(u32, 0x1234), img.getPixel(0, 0));
    try testing.expectEqual(@as(u32, 0x5678), img.getPixel(1, 0));
    try testing.expectEqual(@as(u32, 0x9ABC), img.getPixel(0, 1));
    try testing.expectEqual(@as(u32, 0xDEF0), img.getPixel(1, 1));
}

test "Image.getPixel out of bounds" {
    const data = [_]u8{ 0xFF, 0xFF };
    const img = Image{
        .width = 1,
        .height = 1,
        .data = &data,
        .bytes_per_pixel = 2,
    };

    try testing.expectEqual(@as(u32, 0), img.getPixel(1, 0));
    try testing.expectEqual(@as(u32, 0), img.getPixel(0, 1));
}

test "Image.getPixelTyped u16" {
    const data = [_]u8{ 0x00, 0xF8 };
    const img = Image{
        .width = 1,
        .height = 1,
        .data = &data,
        .bytes_per_pixel = 2,
    };

    try testing.expectEqual(@as(u16, 0xF800), img.getPixelTyped(u16, 0, 0));
}

test "Image.dataSize" {
    const img = Image{
        .width = 10,
        .height = 20,
        .data = &[_]u8{},
        .bytes_per_pixel = 2,
    };

    try testing.expectEqual(@as(usize, 400), img.dataSize());
}
