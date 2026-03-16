//! Runtime crypto suite contract.

const hash = @import("hash.zig");
const hmac = @import("hmac.zig");
const hkdf = @import("hkdf.zig");
const aead = @import("aead.zig");
const pki = @import("pki.zig");

pub const Seal = struct {};

/// Construct a sealed CryptoSuite from an Impl that provides full crypto
/// capabilities for TLS and general use.
///
/// Required:
/// - Hash: `Sha256`, `Sha384`, `Sha512`
/// - HMAC: `HmacSha256`, `HmacSha384`, `HmacSha512`
/// - HKDF: `HkdfSha256`, `HkdfSha384`, `HkdfSha512`
/// - AEAD: `Aes128Gcm`, `Aes256Gcm`, `ChaCha20Poly1305`
/// - PKI:  `Ed25519`, `EcdsaP256Sha256`, `EcdsaP384Sha384`
/// - KEX:  `X25519`, `P256`
/// - Other: `rsa`, `x509`
pub fn CryptoSuite(comptime Impl: type) type {
    comptime {
        _ = hash.Sha256(Impl.Sha256);
        _ = hash.Sha384(Impl.Sha384);
        _ = hash.Sha512(Impl.Sha512);
        _ = hmac.Sha256(Impl.HmacSha256);
        _ = hmac.Sha384(Impl.HmacSha384);
        _ = hmac.Sha512(Impl.HmacSha512);
        _ = hkdf.Sha256(Impl.HkdfSha256);
        _ = hkdf.Sha384(Impl.HkdfSha384);
        _ = hkdf.Sha512(Impl.HkdfSha512);
        _ = aead.Aes128Gcm(Impl.Aes128Gcm);
        _ = aead.Aes256Gcm(Impl.Aes256Gcm);
        _ = aead.ChaCha20Poly1305(Impl.ChaCha20Poly1305);
        _ = pki.from(Impl);
    }

    return struct {
        pub const seal: Seal = .{};

        // --- required ---
        pub const Sha256 = Impl.Sha256;
        pub const HmacSha256 = Impl.HmacSha256;
        pub const HkdfSha256 = Impl.HkdfSha256;
        pub const Aes128Gcm = Impl.Aes128Gcm;
        pub const ChaCha20Poly1305 = Impl.ChaCha20Poly1305;
        pub const Ed25519 = Impl.Ed25519;
        pub const EcdsaP256Sha256 = Impl.EcdsaP256Sha256;
        pub const EcdsaP384Sha384 = Impl.EcdsaP384Sha384;

        pub const Sha384 = Impl.Sha384;
        pub const Sha512 = Impl.Sha512;
        pub const HmacSha384 = Impl.HmacSha384;
        pub const HmacSha512 = Impl.HmacSha512;
        pub const HkdfSha384 = Impl.HkdfSha384;
        pub const HkdfSha512 = Impl.HkdfSha512;
        pub const Aes256Gcm = Impl.Aes256Gcm;

        pub const rsa = Impl.rsa;
        pub const X25519 = Impl.X25519;
        pub const P256 = Impl.P256;
        pub const x509 = Impl.x509;
    };
}

/// Validate that Impl has been sealed via CryptoSuite().
pub fn from(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "seal") or @TypeOf(Impl.seal) != Seal) {
            @compileError("Impl must have pub const seal: suite.Seal — use suite.CryptoSuite(Backend) to construct");
        }
    }

    return Impl;
}
