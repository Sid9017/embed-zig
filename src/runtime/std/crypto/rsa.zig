const std = @import("std");

pub const rsa = struct {
    const StdRsa = std.crypto.Certificate.rsa;

    pub const HashType = enum { sha256, sha384, sha512 };

    pub const PublicKey = struct {
        n: []const u8,
        e: []const u8,

        pub const ParseDerError = error{CertificatePublicKeyInvalid};

        pub fn parseDer(pub_key: []const u8) ParseDerError!struct { modulus: []const u8, exponent: []const u8 } {
            const result = StdRsa.PublicKey.parseDer(pub_key) catch return error.CertificatePublicKeyInvalid;
            return .{ .modulus = result.modulus, .exponent = result.exponent };
        }

        pub fn fromBytes(exponent: []const u8, modulus: []const u8) !PublicKey {
            return PublicKey{ .n = modulus, .e = exponent };
        }
    };

    pub const PKCS1v1_5Signature = struct {
        pub fn verify(
            comptime modulus_len: usize,
            sig: [modulus_len]u8,
            msg: []const u8,
            pk: PublicKey,
            comptime hash_type: HashType,
        ) !void {
            const Hash = switch (hash_type) {
                .sha256 => std.crypto.hash.sha2.Sha256,
                .sha384 => std.crypto.hash.sha2.Sha384,
                .sha512 => std.crypto.hash.sha2.Sha512,
            };
            const std_pk = StdRsa.PublicKey.fromBytes(pk.e, pk.n) catch
                return error.CertificatePublicKeyInvalid;
            StdRsa.PKCS1v1_5Signature.verify(modulus_len, sig, msg, std_pk, Hash) catch
                return error.SignatureVerificationFailed;
        }
    };

    pub const PSSSignature = struct {
        pub fn verify(
            comptime modulus_len: usize,
            sig: [modulus_len]u8,
            msg: []const u8,
            pk: PublicKey,
            comptime hash_type: HashType,
        ) !void {
            const Hash = switch (hash_type) {
                .sha256 => std.crypto.hash.sha2.Sha256,
                .sha384 => std.crypto.hash.sha2.Sha384,
                .sha512 => std.crypto.hash.sha2.Sha512,
            };
            const std_pk = StdRsa.PublicKey.fromBytes(pk.e, pk.n) catch
                return error.CertificatePublicKeyInvalid;
            StdRsa.PSSSignature.verify(modulus_len, sig, msg, std_pk, Hash) catch
                return error.SignatureVerificationFailed;
        }
    };
};

test "rsa wrapper invalid key path" {
    const pk = try rsa.PublicKey.fromBytes(&[_]u8{1}, &[_]u8{1});
    try std.testing.expectError(
        error.CertificatePublicKeyInvalid,
        rsa.PKCS1v1_5Signature.verify(64, [_]u8{0} ** 64, "msg", pk, .sha256),
    );
}
