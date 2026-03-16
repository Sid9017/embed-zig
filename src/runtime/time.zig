//! Runtime Time Contract

const Seal = struct {};

/// Construct a Time wrapper from an Impl type.
/// Impl must provide:
///   pub fn nowMs(Impl) u64
///   pub fn sleepMs(Impl, u32) void
pub fn Time(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn (Impl) u64, &Impl.nowMs);
        _ = @as(*const fn (Impl, u32) void, &Impl.sleepMs);
    }
    const TimeType = struct {
        const impl: Impl = .{};
        pub const seal: Seal = .{};

        pub fn nowMs(_: @This()) u64 {
            return impl.nowMs();
        }

        pub fn sleepMs(_: @This(), ms: u32) void {
            impl.sleepMs(ms);
        }
    };
    return is(TimeType);
}

/// Validate that Impl satisfies the Time contract and return it.
pub fn is(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "seal") or @TypeOf(Impl.seal) != Seal) {
            @compileError("Impl must have pub const seal: time.Seal — use time.Time(Backend) to construct");
        }
    }

    return Impl;
}
