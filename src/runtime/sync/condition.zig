//! Runtime Condition Contract — sealed wrapper over a backend Impl.

const mutex_mod = @import("mutex.zig");

pub const TimedWaitResult = enum {
    signaled,
    timed_out,
};

const Seal = struct {};

/// Construct a sealed Condition wrapper from a backend Impl and raw Mutex type.
/// Impl must provide: init, deinit, wait, signal, broadcast, timedWait.
pub fn Condition(comptime Impl: type, comptime MutexImpl: type) type {
    const SealedMutex = mutex_mod.Mutex(MutexImpl);

    comptime {
        if (@hasDecl(Impl, "MutexType") and Impl.MutexType != MutexImpl) {
            @compileError("Condition.MutexType does not match provided MutexImpl");
        }

        _ = @as(*const fn () Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl, *MutexImpl) void, &Impl.wait);
        _ = @as(*const fn (*Impl) void, &Impl.signal);
        _ = @as(*const fn (*Impl) void, &Impl.broadcast);
        _ = @as(*const fn (*Impl, *MutexImpl, u64) TimedWaitResult, &Impl.timedWait);
    }

    const ConditionType = struct {
        impl: Impl,
        pub const seal: Seal = .{};
        pub const MutexType = SealedMutex;
        pub const BackendType = Impl;

        pub fn init() @This() {
            return .{ .impl = Impl.init() };
        }

        pub fn deinit(self: *@This()) void {
            self.impl.deinit();
        }

        pub fn wait(self: *@This(), mutex: *SealedMutex) void {
            self.impl.wait(&mutex.impl);
        }

        pub fn signal(self: *@This()) void {
            self.impl.signal();
        }

        pub fn broadcast(self: *@This()) void {
            self.impl.broadcast();
        }

        pub fn timedWait(self: *@This(), mutex: *SealedMutex, timeout_ns: u64) TimedWaitResult {
            return self.impl.timedWait(&mutex.impl, timeout_ns);
        }
    };
    return is(ConditionType);
}

/// Validate that Impl satisfies the sealed Condition contract.
pub fn is(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "seal") or @TypeOf(Impl.seal) != Seal) {
            @compileError("Impl must have pub const seal: sync.ConditionSeal — use sync.Condition(Backend) to construct");
        }
    }
    return Impl;
}
 