const std = @import("std");
const embed = @import("embed");
const override_buffer = embed.pkg.audio.override_buffer;

const StdRuntime = embed.runtime.std;

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const Buffer = override_buffer.OverrideBuffer(u8, StdRuntime);
const test_time: StdRuntime.Time = .{};

test "OverrideBuffer: basic write then read" {
    var storage: [8]u8 = undefined;
    var buf = Buffer.init(&storage);
    defer buf.deinit();

    buf.write(&.{ 1, 2, 3, 4 });

    var out: [4]u8 = undefined;
    const n = buf.read(&out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &out);
}

test "OverrideBuffer: overwrite oldest on overflow" {
    var storage: [4]u8 = undefined;
    var buf = Buffer.init(&storage);
    defer buf.deinit();

    buf.write(&.{ 1, 2, 3, 4, 5, 6 });

    try testing.expectEqual(@as(usize, 4), buf.available());

    var out: [4]u8 = undefined;
    const n = buf.read(&out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(u8, &.{ 3, 4, 5, 6 }, &out);
}

test "OverrideBuffer: read drains on close" {
    var storage: [16]u8 = undefined;
    var buf = Buffer.init(&storage);
    defer buf.deinit();

    buf.write(&.{ 10, 20, 30 });
    buf.close();

    var out: [8]u8 = undefined;
    const n = buf.read(&out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, &.{ 10, 20, 30 }, out[0..3]);

    const n2 = buf.read(&out);
    try testing.expectEqual(@as(usize, 0), n2);
}

test "OverrideBuffer: timed read returns partial on timeout" {
    var storage: [16]u8 = undefined;
    var buf = Buffer.init(&storage);
    defer buf.deinit();

    buf.write(&.{ 1, 2 });

    var out: [8]u8 = undefined;
    const n = buf.timedRead(&out, 1_000_000);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, out[0..2]);
}

test "OverrideBuffer: timed read returns zero when empty and timed out" {
    var storage: [16]u8 = undefined;
    var buf = Buffer.init(&storage);
    defer buf.deinit();

    var out: [4]u8 = undefined;
    const n = buf.timedRead(&out, 1_000_000);
    try testing.expectEqual(@as(usize, 0), n);
}

test "OverrideBuffer: reset clears state" {
    var storage: [8]u8 = undefined;
    var buf = Buffer.init(&storage);
    defer buf.deinit();

    buf.write(&.{ 1, 2, 3 });
    buf.close();
    buf.reset();

    try testing.expectEqual(@as(usize, 0), buf.available());
    try testing.expectEqual(false, buf.closed);
}

test "OverrideBuffer: sequential write-read cycles" {
    var storage: [4]u8 = undefined;
    var buf = Buffer.init(&storage);
    defer buf.deinit();

    var out2: [2]u8 = undefined;
    var out1: [1]u8 = undefined;

    buf.write(&.{ 10, 20 });
    _ = buf.read(&out2);
    try testing.expectEqualSlices(u8, &.{ 10, 20 }, &out2);

    buf.write(&.{ 30, 40, 50 });
    _ = buf.read(&out2);
    try testing.expectEqualSlices(u8, &.{ 30, 40 }, &out2);

    _ = buf.read(&out1);
    try testing.expectEqualSlices(u8, &.{50}, &out1);
}

test "OverrideBuffer: blocking read wakes on write from another thread" {
    var storage: [16]u8 = undefined;
    var buf = Buffer.init(&storage);
    defer buf.deinit();

    var th = try StdRuntime.Thread.spawn(.{}, writerTask, @ptrCast(&buf));

    var out: [4]u8 = undefined;
    const n = buf.read(&out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC, 0xDD }, &out);

    th.join();
}

fn writerTask(ctx: ?*anyopaque) void {
    const b: *Buffer = @ptrCast(@alignCast(ctx.?));
    test_time.sleepMs(5);
    b.write(&.{ 0xAA, 0xBB, 0xCC, 0xDD });
}

test "OverrideBuffer: close unblocks waiting reader" {
    var storage: [16]u8 = undefined;
    var buf = Buffer.init(&storage);
    defer buf.deinit();

    var th = try StdRuntime.Thread.spawn(.{}, closerTask, @ptrCast(&buf));

    var out: [4]u8 = undefined;
    const n = buf.read(&out);
    try testing.expectEqual(@as(usize, 0), n);

    th.join();
}

fn closerTask(ctx: ?*anyopaque) void {
    const b: *Buffer = @ptrCast(@alignCast(ctx.?));
    test_time.sleepMs(5);
    b.close();
}

test "OverrideBuffer: comptime with i16 type" {
    const I16Buffer = override_buffer.OverrideBuffer(i16, StdRuntime);
    var storage: [8]i16 = undefined;
    var buf = I16Buffer.init(&storage);
    defer buf.deinit();

    buf.write(&.{ -100, 200, -300, 400 });

    var out: [4]i16 = undefined;
    const n = buf.read(&out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(i16, &.{ -100, 200, -300, 400 }, &out);
}
