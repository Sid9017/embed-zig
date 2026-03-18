//! Runtime crypto PKI/signature contracts.

const Seal = struct {};

pub fn Make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn ([]const u8, []const u8, []const u8) bool, &Impl.verifyEd25519);
        _ = @as(*const fn ([]const u8, []const u8, []const u8) bool, &Impl.verifyEcdsaP256);
        _ = @as(*const fn ([]const u8, []const u8, []const u8) bool, &Impl.verifyEcdsaP384);
    }

    return struct {
        pub const seal: Seal = .{};
        pub const BackendType = Impl;

        pub fn verifyEd25519(sig: []const u8, msg: []const u8, pk: []const u8) bool {
            return Impl.verifyEd25519(sig, msg, pk);
        }

        pub fn verifyEcdsaP256(sig: []const u8, msg: []const u8, pk: []const u8) bool {
            return Impl.verifyEcdsaP256(sig, msg, pk);
        }

        pub fn verifyEcdsaP384(sig: []const u8, msg: []const u8, pk: []const u8) bool {
            return Impl.verifyEcdsaP384(sig, msg, pk);
        }
    };
}

pub fn is(comptime T: type) type {
    comptime {
        if (!@hasDecl(T, "seal") or @TypeOf(T.seal) != Seal) {
            @compileError("Impl must have pub const seal: pki.Seal — use pki.Make(Backend) to construct");
        }
    }
    return T;
}
