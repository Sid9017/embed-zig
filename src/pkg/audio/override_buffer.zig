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
pub const runtime = struct {
    pub const sync = @import("../../runtime/sync.zig");
    pub const std = @import("../../runtime/std.zig");
};

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

            if (!self.closed) {
                _ = self.cond.timedWait(&self.mutex, timeout_ns);
            }

            if (self.closed) return self.drainLocked(out);

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
