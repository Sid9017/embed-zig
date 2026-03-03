//! Runtime crypto suite contract.

const hash = @import("hash.zig");
const hmac = @import("hmac.zig");
const hkdf = @import("hkdf.zig");
const aead = @import("aead.zig");
const pki = @import("pki.zig");

/// Validate an implementation provides TLS baseline crypto capabilities.
///
/// Required:
/// - `Sha256`
/// - `HmacSha256`
/// - `HkdfSha256`
/// - `Aes128Gcm`
/// - `ChaCha20Poly1305`
/// - PKI signature schemes (Ed25519 / EcdsaP256Sha256 / EcdsaP384Sha384)
pub fn from(comptime Impl: type) type {
    comptime {
        _ = hash.Sha256(Impl.Sha256);
        _ = hmac.Sha256(Impl.HmacSha256);
        _ = hkdf.Sha256(Impl.HkdfSha256);
        _ = aead.Aes128Gcm(Impl.Aes128Gcm);
        _ = aead.ChaCha20Poly1305(Impl.ChaCha20Poly1305);
        _ = pki.from(Impl);

        // Optional extension set.
        if (@hasDecl(Impl, "Sha384")) _ = hash.Sha384(Impl.Sha384);
        if (@hasDecl(Impl, "Sha512")) _ = hash.Sha512(Impl.Sha512);
        if (@hasDecl(Impl, "HmacSha384")) _ = hmac.Sha384(Impl.HmacSha384);
        if (@hasDecl(Impl, "HmacSha512")) _ = hmac.Sha512(Impl.HmacSha512);
        if (@hasDecl(Impl, "HkdfSha384")) _ = hkdf.Sha384(Impl.HkdfSha384);
        if (@hasDecl(Impl, "HkdfSha512")) _ = hkdf.Sha512(Impl.HkdfSha512);
        if (@hasDecl(Impl, "Aes256Gcm")) _ = aead.Aes256Gcm(Impl.Aes256Gcm);
    }

    return Impl;
}
