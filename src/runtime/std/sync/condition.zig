const std = @import("std");
const embed = @import("../../../mod.zig");
const condition_contract = embed.runtime.sync;
const Mutex = @import("mutex.zig").Mutex;

pub const Condition = struct {
    raw: std.Thread.Condition = .{},

    pub const MutexType = Mutex;

    pub fn init() @This() {
        return .{};
    }

    pub fn deinit(_: *@This()) void {}

    pub fn wait(self: *@This(), mutex: *Mutex) void {
        self.raw.wait(&mutex.raw);
    }

    pub fn signal(self: *@This()) void {
        self.raw.signal();
    }

    pub fn broadcast(self: *@This()) void {
        self.raw.broadcast();
    }

    pub fn timedWait(self: *@This(), mutex: *Mutex, timeout_ns: u64) condition_contract.TimedWaitResult {
        self.raw.timedWait(&mutex.raw, timeout_ns) catch {
            return .timed_out;
        };
        return .signaled;
    }
};
