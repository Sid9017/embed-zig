//! Runtime RNG Contract

pub const Error = error{
    RngFailed,
};

const Seal = struct {};

/// Construct a sealed Rng wrapper from a backend Impl type.
/// Impl must provide: fill(self: Impl, buf: []u8) Error!void
pub fn Make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn (Impl, []u8) Error!void, &Impl.fill);
    }

    const RngType = struct {
        impl: Impl,
        pub const seal: Seal = .{};
        pub const BackendType = Impl;

        pub fn init() @This() {
            return .{ .impl = .{} };
        }

        pub fn fill(self: @This(), buf: []u8) Error!void {
            return self.impl.fill(buf);
        }
    };
    return is(RngType);
}

/// Validate that Impl satisfies the sealed Rng contract.
pub fn is(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "seal") or @TypeOf(Impl.seal) != Seal) {
            @compileError("Impl must have pub const seal: rng.Seal — use rng.Make(Backend) to construct");
        }
    }
    return Impl;
}
