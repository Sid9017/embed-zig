//! Runtime Notify Contract — sealed wrapper over a backend Impl.

const Seal = struct {};

/// Construct a sealed Notify wrapper from a backend Impl type.
/// Impl must provide: init, deinit, signal, wait, timedWait.
pub fn Notify(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl) void, &Impl.signal);
        _ = @as(*const fn (*Impl) void, &Impl.wait);
        _ = @as(*const fn (*Impl, u64) bool, &Impl.timedWait);
    }

    const NotifyType = struct {
        impl: Impl,
        pub const seal: Seal = .{};
        pub const BackendType = Impl;

        pub fn init() @This() {
            return .{ .impl = Impl.init() };
        }

        pub fn deinit(self: *@This()) void {
            self.impl.deinit();
        }

        pub fn signal(self: *@This()) void {
            self.impl.signal();
        }

        pub fn wait(self: *@This()) void {
            self.impl.wait();
        }

        pub fn timedWait(self: *@This(), timeout_ns: u64) bool {
            return self.impl.timedWait(timeout_ns);
        }
    };
    return is(NotifyType);
}

/// Validate that Impl satisfies the sealed Notify contract.
pub fn is(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "seal") or @TypeOf(Impl.seal) != Seal) {
            @compileError("Impl must have pub const seal: sync.NotifySeal — use sync.Notify(Backend) to construct");
        }
    }
    return Impl;
}
