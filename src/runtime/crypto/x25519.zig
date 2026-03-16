//! Runtime crypto X25519 key-exchange contract.

const Seal = struct {};

pub const KeyPair = struct {
    public_key: [32]u8,
    secret_key: [32]u8,
};

pub fn Make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn ([32]u8) anyerror!KeyPair, &Impl.generateDeterministic);
        _ = @as(*const fn ([32]u8, [32]u8) anyerror![32]u8, &Impl.scalarmult);
    }

    return struct {
        pub const seal: Seal = .{};
        pub const BackendType = Impl;

        pub fn generateDeterministic(seed: [32]u8) !KeyPair {
            return Impl.generateDeterministic(seed);
        }

        pub fn scalarmult(secret: [32]u8, public: [32]u8) ![32]u8 {
            return Impl.scalarmult(secret, public);
        }
    };
}

pub fn is(comptime T: type) type {
    comptime {
        if (!@hasDecl(T, "seal") or @TypeOf(T.seal) != Seal) {
            @compileError("Impl must have pub const seal: x25519.Seal — use x25519.Make(Backend) to construct");
        }
    }
    return T;
}
