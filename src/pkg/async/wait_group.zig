const std = @import("std");
pub const runtime = struct {
    pub const sync = @import("../../runtime/sync.zig");
    pub const std = @import("../../runtime/std.zig");
};

pub const WaitGroupError = error{
    Underflow,
};

pub const CallbackFn = *const fn (?*anyopaque) void;

/// Wait group parameterized on explicit sync primitives.
/// Uses `Mutex` and `Condition` for thread-safe blocking `wait()`.
/// Also supports cooperative polling via `isDone()` and completion callbacks.
pub fn WaitGroup(comptime Mutex: type, comptime Cond: type) type {
    comptime {
        _ = runtime.sync.Mutex(Mutex);
        _ = runtime.sync.ConditionWithMutex(Cond, Mutex);
    }

    return struct {
        const Self = @This();

        mutex: Mutex,
        cond: Cond,
        pending: usize = 0,
        on_complete_fn: ?CallbackFn = null,
        on_complete_ctx: ?*anyopaque = null,

        pub fn init() Self {
            return .{
                .mutex = Mutex.init(),
                .cond = Cond.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.cond.deinit();
            self.mutex.deinit();
        }

        pub fn add(self: *Self, n: usize) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.pending += n;
        }

        pub fn done(self: *Self) WaitGroupError!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.pending == 0) return error.Underflow;
            self.pending -= 1;
            if (self.pending == 0) {
                if (self.on_complete_fn) |func| {
                    func(self.on_complete_ctx);
                }
                self.cond.broadcast();
            }
        }

        /// Blocking wait — returns when pending reaches zero.
        pub fn wait(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.pending > 0) {
                self.cond.wait(&self.mutex);
            }
        }

        pub fn isDone(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.pending == 0;
        }

        pub fn remaining(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.pending;
        }

        pub fn onComplete(self: *Self, func: CallbackFn, ctx: ?*anyopaque) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.on_complete_fn = func;
            self.on_complete_ctx = ctx;
        }

        pub fn reset(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.pending = 0;
            self.on_complete_fn = null;
            self.on_complete_ctx = null;
        }
    };
}
