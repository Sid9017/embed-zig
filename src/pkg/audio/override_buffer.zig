//! OverrideBuffer — fixed-capacity circular buffer with non-blocking write
//! and blocking read.
//!
//! Write always succeeds immediately, silently overwriting the oldest data
//! when the buffer is full.  Read blocks the caller until at least the
//! requested amount of data (or *some* data) is available.
//!
//! Designed for audio streaming where the producer must never stall and the
//! consumer can afford to wait.

const std = @import("std");
const runtime = @import("runtime");

pub fn OverrideBuffer(
    comptime T: type,
    comptime MutexImpl: type,
    comptime ConditionImpl: type,
) type {
    comptime _ = runtime.sync.Mutex(MutexImpl);
    comptime _ = runtime.sync.ConditionWithMutex(ConditionImpl, MutexImpl);

    return struct {
        const Self = @This();

        buf: []T,
        capacity: usize,

        write_pos: usize = 0,
        read_pos: usize = 0,
        len: usize = 0,

        mutex: MutexImpl,
        cond: ConditionImpl,
        closed: bool = false,

        pub fn init(buf: []T) Self {
            return .{
                .buf = buf,
                .capacity = buf.len,
                .mutex = MutexImpl.init(),
                .cond = ConditionImpl.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.cond.deinit();
            self.mutex.deinit();
        }

        /// Non-blocking write.  Overwrites oldest unread data when full.
        pub fn write(self: *Self, data: []const T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (data) |sample| {
                self.buf[self.write_pos] = sample;
                self.write_pos = (self.write_pos + 1) % self.capacity;

                if (self.len < self.capacity) {
                    self.len += 1;
                } else {
                    self.read_pos = (self.read_pos + 1) % self.capacity;
                }
            }

            if (data.len > 0) self.cond.signal();
        }

        /// Blocking read.  Waits until `out.len` elements are available, then
        /// copies them into `out`.  Returns the number of elements read, which
        /// equals `out.len` under normal operation.
        ///
        /// Returns 0 only when the buffer has been closed and drained.
        pub fn read(self: *Self, out: []T) usize {
            if (out.len == 0) return 0;

            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.len < out.len) {
                if (self.closed) {
                    return self.drainLocked(out);
                }
                self.cond.wait(&self.mutex);
            }

            return self.copyOutLocked(out, out.len);
        }

        /// Blocking read with timeout (nanoseconds).
        /// Returns the number of elements actually read.  May be less than
        /// `out.len` if the timeout fires before enough data arrives.
        /// Returns 0 on timeout with no data, or when closed and drained.
        pub fn timedRead(self: *Self, out: []T, timeout_ns: u64) usize {
            if (out.len == 0) return 0;

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.len >= out.len) {
                return self.copyOutLocked(out, out.len);
            }

            const start = nowNs();
            const deadline = if (timeout_ns > std.math.maxInt(u64) - start)
                std.math.maxInt(u64)
            else
                start + timeout_ns;

            while (self.len < out.len) {
                if (self.closed) return self.drainLocked(out);

                const now = nowNs();
                if (now >= deadline) break;

                _ = self.cond.timedWait(&self.mutex, deadline - now);
            }

            const n = @min(self.len, out.len);
            return self.copyOutLocked(out, n);
        }

        /// Signal that no more data will be written.
        /// Wakes all blocked readers so they can drain and return.
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.cond.broadcast();
        }

        /// Reset to empty, open state.
        pub fn reset(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.write_pos = 0;
            self.read_pos = 0;
            self.len = 0;
            self.closed = false;
        }

        /// Number of elements available for reading (snapshot, may race).
        pub fn available(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.len;
        }

        // -- internal helpers (caller holds mutex) ---------------------------

        fn copyOutLocked(self: *Self, out: []T, n: usize) usize {
            for (0..n) |i| {
                out[i] = self.buf[self.read_pos];
                self.read_pos = (self.read_pos + 1) % self.capacity;
            }
            self.len -= n;
            return n;
        }

        fn drainLocked(self: *Self, out: []T) usize {
            if (self.len == 0) return 0;
            const n = @min(self.len, out.len);
            return self.copyOutLocked(out, n);
        }
    };
}

fn nowNs() u64 {
    const ts = std.time.nanoTimestamp();
    return if (ts <= 0) 0 else @intCast(ts);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const TestMutex = runtime.std.Mutex;
const TestCondition = runtime.std.Condition;
const TestThread = runtime.std.Thread;
const test_time: runtime.std.Time = .{};

const Buffer = OverrideBuffer(u8, TestMutex, TestCondition);

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

    var th = try TestThread.spawn(.{}, writerTask, @ptrCast(&buf));

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

    var th = try TestThread.spawn(.{}, closerTask, @ptrCast(&buf));

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
    const I16Buffer = OverrideBuffer(i16, TestMutex, TestCondition);
    var storage: [8]i16 = undefined;
    var buf = I16Buffer.init(&storage);
    defer buf.deinit();

    buf.write(&.{ -100, 200, -300, 400 });

    var out: [4]i16 = undefined;
    const n = buf.read(&out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(i16, &.{ -100, 200, -300, 400 }, &out);
}
