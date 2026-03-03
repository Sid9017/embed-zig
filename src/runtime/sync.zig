//! Runtime Sync Contracts — Mutex / Condition / Notify

/// Shared contract data types (namespaced to avoid ad-hoc per-impl definitions).
pub const types = struct {
    /// Shared timed-wait result for all Condition implementations.
    pub const TimedWaitResult = enum {
        signaled,
        timed_out,
    };
};

/// Validate that `Impl` is a valid Mutex type.
pub fn Mutex(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl) void, &Impl.lock);
        _ = @as(*const fn (*Impl) void, &Impl.unlock);
    }
    return Impl;
}

/// Validate that `Impl` is a valid Condition type for the given `MutexImpl`.
///
/// Preferred usage:
/// - Condition impl declares `pub const MutexType = ...`
/// - call `Condition(Impl)`
pub fn Condition(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "MutexType")) {
            @compileError("Condition missing MutexType (declare `pub const MutexType = ...`)");
        }
    }
    return ConditionWithMutex(Impl, Impl.MutexType);
}

/// Explicit binding form (kept for call sites that want to pass mutex type directly).
pub fn ConditionWithMutex(comptime Impl: type, comptime MutexImpl: type) type {
    comptime {
        // Explicitly validate Mutex contract first.
        const M = Mutex(MutexImpl);

        if (@hasDecl(Impl, "MutexType") and Impl.MutexType != M) {
            @compileError("Condition.MutexType does not match provided MutexImpl");
        }

        _ = @as(*const fn () Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl, *M) void, &Impl.wait);
        _ = @as(*const fn (*Impl) void, &Impl.signal);
        _ = @as(*const fn (*Impl) void, &Impl.broadcast);
        _ = @as(*const fn (*Impl, *M, u64) types.TimedWaitResult, &Impl.timedWait);
    }
    return Impl;
}

/// Validate that `Impl` is a valid Notify type.
pub fn Notify(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl) void, &Impl.signal);
        _ = @as(*const fn (*Impl) void, &Impl.wait);
        _ = @as(*const fn (*Impl, u64) bool, &Impl.timedWait);
    }
    return Impl;
}
