const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const dirty = embed.pkg.ui.render.dirty;

// ============================================================================
// Tests
// ============================================================================

test "Rect.intersects: overlapping" {
    const a = dirty.Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b = dirty.Rect{ .x = 5, .y = 5, .w = 10, .h = 10 };
    try testing.expect(a.intersects(b));
    try testing.expect(b.intersects(a));
}

test "Rect.intersects: adjacent (no overlap)" {
    const a = dirty.Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b = dirty.Rect{ .x = 10, .y = 0, .w = 10, .h = 10 };
    try testing.expect(!a.intersects(b));
}

test "Rect.intersects: zero-size" {
    const a = dirty.Rect{ .x = 5, .y = 5, .w = 0, .h = 10 };
    const b = dirty.Rect{ .x = 0, .y = 0, .w = 20, .h = 20 };
    try testing.expect(!a.intersects(b));
}

test "Rect.merge: bounding box" {
    const a = dirty.Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    const b = dirty.Rect{ .x = 5, .y = 50, .w = 10, .h = 20 };
    const m = a.merge(b);
    try testing.expectEqual(@as(u16, 5), m.x);
    try testing.expectEqual(@as(u16, 20), m.y);
    try testing.expectEqual(@as(u16, 35), m.w);
    try testing.expectEqual(@as(u16, 50), m.h);
}

test "Rect.merge: with zero-size returns other" {
    const zero = dirty.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
    const real = dirty.Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try testing.expect(zero.merge(real).eql(real));
    try testing.expect(real.merge(zero).eql(real));
}

test "DirtyTracker: mark and get" {
    var dt = dirty.DirtyTracker(4).init();
    try testing.expect(!dt.isDirty());

    dt.mark(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    try testing.expect(dt.isDirty());
    try testing.expectEqual(@as(u8, 1), dt.count);

    dt.mark(.{ .x = 100, .y = 100, .w = 20, .h = 20 });
    try testing.expectEqual(@as(u8, 2), dt.count);
}

test "DirtyTracker: overlapping rects merge automatically" {
    var dt = dirty.DirtyTracker(4).init();
    dt.mark(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    dt.mark(.{ .x = 5, .y = 5, .w = 10, .h = 10 });
    try testing.expectEqual(@as(u8, 1), dt.count);

    const r = dt.get()[0];
    try testing.expectEqual(@as(u16, 0), r.x);
    try testing.expectEqual(@as(u16, 0), r.y);
    try testing.expectEqual(@as(u16, 15), r.w);
    try testing.expectEqual(@as(u16, 15), r.h);
}

test "DirtyTracker: collapse when full" {
    var dt = dirty.DirtyTracker(2).init();
    dt.mark(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    dt.mark(.{ .x = 50, .y = 50, .w = 10, .h = 10 });
    dt.mark(.{ .x = 200, .y = 200, .w = 5, .h = 5 });

    try testing.expectEqual(@as(u8, 2), dt.count);
}

test "DirtyTracker: markAll resets to single full-screen rect" {
    var dt = dirty.DirtyTracker(4).init();
    dt.mark(.{ .x = 10, .y = 10, .w = 5, .h = 5 });
    dt.mark(.{ .x = 100, .y = 100, .w = 5, .h = 5 });
    dt.markAll(240, 240);

    try testing.expectEqual(@as(u8, 1), dt.count);
    const r = dt.get()[0];
    try testing.expectEqual(@as(u16, 0), r.x);
    try testing.expectEqual(@as(u16, 0), r.y);
    try testing.expectEqual(@as(u16, 240), r.w);
    try testing.expectEqual(@as(u16, 240), r.h);
}

test "DirtyTracker: clear" {
    var dt = dirty.DirtyTracker(4).init();
    dt.mark(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    dt.clear();
    try testing.expect(!dt.isDirty());
    try testing.expectEqual(@as(usize, 0), dt.get().len);
}

test "DirtyTracker: zero-size rect ignored" {
    var dt = dirty.DirtyTracker(4).init();
    dt.mark(.{ .x = 10, .y = 10, .w = 0, .h = 5 });
    try testing.expect(!dt.isDirty());
}
