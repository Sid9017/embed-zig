const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const ring_buffer = embed.pkg.event.ring_buffer;

// ============================================================================
// Tests
// ============================================================================

test "RingBuffer: basic push and get" {
    var buf = ring_buffer.RingBuffer(u32, 4).init();

    try std.testing.expectEqual(@as(usize, 0), buf.count());
    try std.testing.expect(buf.isEmpty());

    _ = buf.push(10);
    _ = buf.push(20);
    _ = buf.push(30);

    try std.testing.expectEqual(@as(usize, 3), buf.count());
    try std.testing.expect(!buf.isEmpty());
    try std.testing.expect(!buf.isFull());

    try std.testing.expectEqual(@as(u32, 10), buf.get(0).?.*);
    try std.testing.expectEqual(@as(u32, 20), buf.get(1).?.*);
    try std.testing.expectEqual(@as(u32, 30), buf.get(2).?.*);
    try std.testing.expect(buf.get(3) == null);
}

test "RingBuffer: first and last" {
    var buf = ring_buffer.RingBuffer(u32, 4).init();

    try std.testing.expect(buf.getFirst() == null);
    try std.testing.expect(buf.getLast() == null);

    _ = buf.push(1);
    _ = buf.push(2);
    _ = buf.push(3);

    try std.testing.expectEqual(@as(u32, 1), buf.getFirst().?.*);
    try std.testing.expectEqual(@as(u32, 3), buf.getLast().?.*);
}

test "RingBuffer: reverse indexing" {
    var buf = ring_buffer.RingBuffer(u32, 4).init();

    _ = buf.push(10);
    _ = buf.push(20);
    _ = buf.push(30);

    try std.testing.expectEqual(@as(u32, 30), buf.getReverse(0).?.*); // newest
    try std.testing.expectEqual(@as(u32, 20), buf.getReverse(1).?.*);
    try std.testing.expectEqual(@as(u32, 10), buf.getReverse(2).?.*); // oldest
    try std.testing.expect(buf.getReverse(3) == null);
}

test "RingBuffer: overwrite when full" {
    var buf = ring_buffer.RingBuffer(u32, 3).init();

    _ = buf.push(1);
    _ = buf.push(2);
    _ = buf.push(3);
    try std.testing.expect(buf.isFull());

    // This should overwrite 1
    const result = buf.pushOverwrite(4);
    try std.testing.expect(result.overwritten);

    try std.testing.expectEqual(@as(usize, 3), buf.count());
    try std.testing.expectEqual(@as(u32, 2), buf.get(0).?.*); // oldest is now 2
    try std.testing.expectEqual(@as(u32, 3), buf.get(1).?.*);
    try std.testing.expectEqual(@as(u32, 4), buf.get(2).?.*); // newest

    // Overwrite again
    _ = buf.push(5);
    try std.testing.expectEqual(@as(u32, 3), buf.get(0).?.*);
    try std.testing.expectEqual(@as(u32, 5), buf.getLast().?.*);
}

test "RingBuffer: iterator" {
    var buf = ring_buffer.RingBuffer(u32, 4).init();

    _ = buf.push(10);
    _ = buf.push(20);
    _ = buf.push(30);

    var sum: u32 = 0;
    var iter = buf.iterator();
    while (iter.next()) |val| {
        sum += val.*;
    }

    try std.testing.expectEqual(@as(u32, 60), sum);
}

test "RingBuffer: iterator after wrap" {
    var buf = ring_buffer.RingBuffer(u32, 3).init();

    _ = buf.push(1);
    _ = buf.push(2);
    _ = buf.push(3);
    _ = buf.push(4); // overwrites 1
    _ = buf.push(5); // overwrites 2

    var values: [3]u32 = undefined;
    var i: usize = 0;
    var iter = buf.iterator();
    while (iter.next()) |val| {
        values[i] = val.*;
        i += 1;
    }

    try std.testing.expectEqual(@as(u32, 3), values[0]);
    try std.testing.expectEqual(@as(u32, 4), values[1]);
    try std.testing.expectEqual(@as(u32, 5), values[2]);
}

test "RingBuffer: clear" {
    var buf = ring_buffer.RingBuffer(u32, 4).init();

    _ = buf.push(1);
    _ = buf.push(2);
    buf.clear();

    try std.testing.expect(buf.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), buf.count());
}

test "RingBuffer: modify through pointer" {
    var buf = ring_buffer.RingBuffer(u32, 4).init();

    const ptr = buf.push(10);
    ptr.* = 99;

    try std.testing.expectEqual(@as(u32, 99), buf.get(0).?.*);
}

test "RingBuffer: struct element" {
    const Item = struct {
        x: i32,
        y: i32,
    };

    var buf = ring_buffer.RingBuffer(Item, 4).init();

    _ = buf.push(.{ .x = 1, .y = 2 });
    _ = buf.push(.{ .x = 3, .y = 4 });

    const first = buf.getFirst().?;
    try std.testing.expectEqual(@as(i32, 1), first.x);
    try std.testing.expectEqual(@as(i32, 2), first.y);

    // Modify through pointer
    buf.getLast().?.x = 100;
    try std.testing.expectEqual(@as(i32, 100), buf.getLast().?.x);
}
