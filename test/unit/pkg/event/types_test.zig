const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const types = embed.pkg.event.types;

test "PeriphEvent can be instantiated" {
    const ev = types.PeriphEvent{ .id = "btn.test", .code = 2, .data = 3 };
    try std.testing.expectEqualStrings("btn.test", ev.id);
    try std.testing.expectEqual(@as(u16, 2), ev.code);
}

test "assertTaggedUnion accepts tagged union" {
    const Good = union(enum) { a: u32, b: f32 };
    comptime types.assertTaggedUnion(Good);
}
