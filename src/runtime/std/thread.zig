const std = @import("std");
const runtime = @import("../runtime.zig");

pub const StdThread = struct {
    handle: ?std.Thread = null,

    pub fn spawn(config: runtime.thread.types.SpawnConfig, task: runtime.thread.types.TaskFn, ctx: ?*anyopaque) anyerror!@This() {
        _ = config.name;
        const handle = try std.Thread.spawn(.{ .stack_size = config.stack_size }, runTask, .{ task, ctx });
        return .{ .handle = handle };
    }

    pub fn join(self: *@This()) void {
        if (self.handle) |h| {
            h.join();
            self.handle = null;
        }
    }

    pub fn detach(self: *@This()) void {
        if (self.handle) |h| {
            h.detach();
            self.handle = null;
        }
    }

    fn runTask(task: runtime.thread.types.TaskFn, ctx: ?*anyopaque) void {
        task(ctx);
    }
};
