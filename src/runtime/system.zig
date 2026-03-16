//! Runtime System Contract

/// Fixed error set for system queries.
pub const Error = error{
    Unsupported,
    QueryFailed,
};

const Seal = struct {};

/// Construct a sealed System wrapper from a backend Impl type.
/// Impl must provide: getCpuCount(self: Impl) Error!usize
pub fn System(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn (Impl) Error!usize, &Impl.getCpuCount);
    }

    const SystemType = struct {
        const impl: Impl = .{};
        pub const seal: Seal = .{};
        pub const BackendType = Impl;

        pub fn getCpuCount(_: @This()) Error!usize {
            return impl.getCpuCount();
        }
    };
    return is(SystemType);
}

/// Validate that Impl satisfies the sealed System contract.
pub fn is(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "seal") or @TypeOf(Impl.seal) != Seal) {
            @compileError("Impl must have pub const seal: system.Seal — use system.System(Backend) to construct");
        }
    }
    return Impl;
}
