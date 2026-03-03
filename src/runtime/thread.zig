//! Runtime Thread Contract

/// Shared thread-related contract types.
pub const types = struct {
    pub const SpawnConfig = struct {
        stack_size: usize = 8192,
        name: ?[]const u8 = null,
    };

    pub const TaskFn = *const fn (?*anyopaque) void;
};

/// Thread contract:
/// - `spawn(config: SpawnConfig, task: TaskFn, ctx: ?*anyopaque) -> anyerror!Impl`
/// - `join(self: *Impl) -> void`
/// - `detach(self: *Impl) -> void`
pub fn from(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn (types.SpawnConfig, types.TaskFn, ?*anyopaque) anyerror!Impl, &Impl.spawn);
        _ = @as(*const fn (*Impl) void, &Impl.join);
        _ = @as(*const fn (*Impl) void, &Impl.detach);
    }
    return Impl;
}
