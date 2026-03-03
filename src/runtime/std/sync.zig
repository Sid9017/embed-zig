const std = @import("std");
const runtime = @import("../runtime.zig");

fn nowNs() u64 {
    const ts = std.time.nanoTimestamp();
    return if (ts <= 0) 0 else @intCast(ts);
}

pub const StdMutex = struct {
    raw: std.Thread.Mutex = .{},

    pub fn init() @This() {
        return .{};
    }

    pub fn deinit(_: *@This()) void {}

    pub fn lock(self: *@This()) void {
        self.raw.lock();
    }

    pub fn unlock(self: *@This()) void {
        self.raw.unlock();
    }
};

pub const StdCondition = struct {
    raw: std.Thread.Condition = .{},

    pub const MutexType = StdMutex;

    pub fn init() @This() {
        return .{};
    }

    pub fn deinit(_: *@This()) void {}

    pub fn wait(self: *@This(), mutex: *StdMutex) void {
        self.raw.wait(&mutex.raw);
    }

    pub fn signal(self: *@This()) void {
        self.raw.signal();
    }

    pub fn broadcast(self: *@This()) void {
        self.raw.broadcast();
    }

    pub fn timedWait(self: *@This(), mutex: *StdMutex, timeout_ns: u64) runtime.sync.types.TimedWaitResult {
        self.raw.timedWait(&mutex.raw, timeout_ns) catch {
            return .timed_out;
        };
        return .signaled;
    }
};

pub const StdNotify = struct {
    mutex: StdMutex = StdMutex.init(),
    cond: StdCondition = StdCondition.init(),
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
