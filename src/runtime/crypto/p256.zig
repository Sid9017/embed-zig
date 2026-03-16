//! Runtime crypto P256 key-exchange contract.

const Seal = struct {};

pub fn Make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn ([32]u8) anyerror![65]u8, &Impl.computePublicKey);
        _ = @as(*const fn ([32]u8, [65]u8) anyerror![32]u8, &Impl.ecdh);
    }

    return struct {
        pub const seal: Seal = .{};
        pub const BackendType = Impl;

        pub fn computePublicKey(secret_key: [32]u8) ![65]u8 {
            return Impl.computePublicKey(secret_key);
        }

        pub fn ecdh(secret_key: [32]u8, peer_public: [65]u8) ![32]u8 {
            return Impl.ecdh(secret_key, peer_public);
        }
    };
}

pub fn is(comptime T: type) type {
    comptime {
        if (!@hasDecl(T, "seal") or @TypeOf(T.seal) != Seal) {
            @compileError("Impl must have pub const seal: p256.Seal — use p256.Make(Backend) to construct");
        }
    }
    return T;
}
