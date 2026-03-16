const std = @import("std");
const Mutex = @import("mutex.zig").Mutex;
const Condition = @import("condition.zig").Condition;

fn nowNs() u64 {
    const ts = std.time.nanoTimestamp();
    return if (ts <= 0) 0 else @intCast(ts);
}

pub const Notify = struct {
    mutex: Mutex = Mutex.init(),
    cond: Condition = Condition.init(),
    pending: u32 = 0,

    pub fn init() @This() {
        return .{};
    }

    pub fn deinit(self: *@This()) void {
        self.cond.deinit();
        self.mutex.deinit();
    }

    pub fn signal(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pending += 1;
        self.cond.signal();
    }

    pub fn wait(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.pending == 0) {
            self.cond.wait(&self.mutex);
        }
        self.pending -= 1;
    }

    pub fn timedWait(self: *@This(), timeout_ns: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending > 0) {
            self.pending -= 1;
            return true;
        }

        const start = nowNs();
        const deadline = if (timeout_ns > std.math.maxInt(u64) - start)
            std.math.maxInt(u64)
        else
            start + timeout_ns;
        while (self.pending == 0) {
            const now = nowNs();
            if (now >= deadline) return false;

            const remaining = deadline - now;
            const result = self.cond.timedWait(&self.mutex, remaining);
            if (result == .timed_out and self.pending == 0) return false;
        }

        self.pending -= 1;
        return true;
    }
};
