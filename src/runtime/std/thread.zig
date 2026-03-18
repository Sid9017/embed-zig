const std = @import("std");
const embed = @import("../../mod.zig");

const SpawnConfig = embed.runtime.thread.SpawnConfig;

pub const Thread = struct {
    handle: ?std.Thread = null,

    pub fn spawn(config: SpawnConfig, task: embed.runtime.thread.TaskFn, ctx: ?*anyopaque) anyerror!@This() {
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

    fn runTask(task: embed.runtime.thread.TaskFn, ctx: ?*anyopaque) void {
        task(ctx);
    }
};
