//! Runtime Thread Contract

const std = @import("std");

pub const TaskFn = *const fn (?*anyopaque) void;

pub const SpawnConfig = struct {
    stack_size: usize = 8192,
    priority: u8 = 5,
    name: [*:0]const u8 = "task",
    core_id: ?i32 = null,
    allocator: ?std.mem.Allocator = null,
};

const Seal = struct {};

/// Construct a Thread wrapper from an Impl type.
/// Impl must provide:
///   pub fn spawn(SpawnConfig, TaskFn, ?*anyopaque) anyerror!Impl
///   pub fn join(*Impl) void
///   pub fn detach(*Impl) void
///
/// The returned type is both the factory and instance type: spawn returns @This(),
/// so callers can store the result and call join/detach on it.
pub fn Thread(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn (SpawnConfig, TaskFn, ?*anyopaque) anyerror!Impl, &Impl.spawn);
        _ = @as(*const fn (*Impl) void, &Impl.join);
        _ = @as(*const fn (*Impl) void, &Impl.detach);
    }

    const ThreadType = struct {
        impl: Impl,
        pub const seal: Seal = .{};

        pub fn spawn(config: SpawnConfig, task: TaskFn, ctx: ?*anyopaque) anyerror!@This() {
            return .{ .impl = try Impl.spawn(config, task, ctx) };
        }

        pub fn join(self: *@This()) void {
            self.impl.join();
        }

        pub fn detach(self: *@This()) void {
            self.impl.detach();
        }
    };
    return is(ThreadType);
}

/// Validate that Impl satisfies the Thread contract and return it.
pub fn is(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "seal") or @TypeOf(Impl.seal) != Seal) {
            @compileError("Impl must have pub const seal: thread.Seal — use thread.Thread(Backend) to construct");
        }
    }

    return Impl;
}
