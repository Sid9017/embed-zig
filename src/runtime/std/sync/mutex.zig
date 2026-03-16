const std = @import("std");

pub const Mutex = struct {
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
