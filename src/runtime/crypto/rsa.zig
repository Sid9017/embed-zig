//! Runtime crypto RSA contracts.

const Seal = struct {};

pub const HashType = enum { sha256, sha384, sha512 };

pub const DerKey = struct {
    modulus: []const u8,
    exponent: []const u8,
};

pub fn Make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn ([]const u8, []const u8, []const u8, HashType) anyerror!void, &Impl.verifyPKCS1v1_5);
        _ = @as(*const fn ([]const u8, []const u8, []const u8, HashType) anyerror!void, &Impl.verifyPSS);
        _ = @as(*const fn ([]const u8) anyerror!DerKey, &Impl.parseDer);
    }

    return struct {
        pub const seal: Seal = .{};
        pub const BackendType = Impl;

        pub fn verifyPKCS1v1_5(sig: []const u8, msg: []const u8, pk: []const u8, hash_type: HashType) !void {
            return Impl.verifyPKCS1v1_5(sig, msg, pk, hash_type);
        }

        pub fn verifyPSS(sig: []const u8, msg: []const u8, pk: []const u8, hash_type: HashType) !void {
            return Impl.verifyPSS(sig, msg, pk, hash_type);
        }

        pub fn parseDer(pub_key: []const u8) !DerKey {
            return Impl.parseDer(pub_key);
        }
    };
}

pub fn is(comptime T: type) type {
    comptime {
        if (!@hasDecl(T, "seal") or @TypeOf(T.seal) != Seal) {
            @compileError("Impl must have pub const seal: rsa.Seal — use rsa.Make(Backend) to construct");
        }
    }
    return T;
}
