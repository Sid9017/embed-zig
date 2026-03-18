//! Runtime Mutex Contract — sealed wrapper over a backend Impl.

const Seal = struct {};

/// Construct a sealed Mutex wrapper from a backend Impl type.
/// Impl must provide: init, deinit, lock, unlock.
pub fn Make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl) void, &Impl.lock);
        _ = @as(*const fn (*Impl) void, &Impl.unlock);
    }

    const MutexType = struct {
        impl: Impl,
        pub const seal: Seal = .{};
        pub const BackendType = Impl;

        pub fn init() @This() {
            return .{ .impl = Impl.init() };
        }

        pub fn deinit(self: *@This()) void {
            self.impl.deinit();
        }

        pub fn lock(self: *@This()) void {
            self.impl.lock();
        }

        pub fn unlock(self: *@This()) void {
            self.impl.unlock();
        }
    };
    return is(MutexType);
}

/// Validate that Impl satisfies the sealed Mutex contract.
pub fn is(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "seal") or @TypeOf(Impl.seal) != Seal) {
            @compileError("Impl must have pub const seal: mutex.Seal — use mutex.Make(Backend) to construct");
        }
    }
    return Impl;
}
