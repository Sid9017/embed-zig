const std = @import("std");
const rsa_contract = @import("../../crypto/rsa.zig");

const StdRsa = std.crypto.Certificate.rsa;

fn StdHash(comptime ht: rsa_contract.HashType) type {
    return switch (ht) {
        .sha256 => std.crypto.hash.sha2.Sha256,
        .sha384 => std.crypto.hash.sha2.Sha384,
        .sha512 => std.crypto.hash.sha2.Sha512,
    };
}

fn resolveKey(pk_der: []const u8) !StdRsa.PublicKey {
    const parsed = StdRsa.PublicKey.parseDer(pk_der) catch return error.CertificatePublicKeyInvalid;
    return StdRsa.PublicKey.fromBytes(parsed.exponent, parsed.modulus) catch return error.CertificatePublicKeyInvalid;
}

pub fn verifyPKCS1v1_5(sig: []const u8, msg: []const u8, pk_der: []const u8, hash_type: rsa_contract.HashType) anyerror!void {
    const pk = try resolveKey(pk_der);
    switch (hash_type) {
        inline else => |ht| {
            const Hash = StdHash(ht);
            switch (sig.len) {
                128 => StdRsa.PKCS1v1_5Signature.verify(128, sig[0..128].*, msg, pk, Hash) catch
                    return error.SignatureVerificationFailed,
                256 => StdRsa.PKCS1v1_5Signature.verify(256, sig[0..256].*, msg, pk, Hash) catch
                    return error.SignatureVerificationFailed,
                512 => StdRsa.PKCS1v1_5Signature.verify(512, sig[0..512].*, msg, pk, Hash) catch
                    return error.SignatureVerificationFailed,
                else => return error.UnsupportedModulusLength,
            }
        },
    }
}

pub fn verifyPSS(sig: []const u8, msg: []const u8, pk_der: []const u8, hash_type: rsa_contract.HashType) anyerror!void {
    const pk = try resolveKey(pk_der);
    switch (hash_type) {
        inline else => |ht| {
            const Hash = StdHash(ht);
            switch (sig.len) {
                128 => StdRsa.PSSSignature.verify(128, sig[0..128].*, msg, pk, Hash) catch
                    return error.SignatureVerificationFailed,
                256 => StdRsa.PSSSignature.verify(256, sig[0..256].*, msg, pk, Hash) catch
                    return error.SignatureVerificationFailed,
                512 => StdRsa.PSSSignature.verify(512, sig[0..512].*, msg, pk, Hash) catch
                    return error.SignatureVerificationFailed,
                else => return error.UnsupportedModulusLength,
            }
        },
    }
}

pub fn parseDer(pub_key: []const u8) anyerror!struct { modulus: []const u8, exponent: []const u8 } {
    const result = StdRsa.PublicKey.parseDer(pub_key) catch return error.CertificatePublicKeyInvalid;
    return .{ .modulus = result.modulus, .exponent = result.exponent };
}
