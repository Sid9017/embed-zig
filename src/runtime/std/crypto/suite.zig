//! std crypto suite — assembles Zig std.crypto primitives into a
//! CryptoSuite backend.

const hash_mod = @import("hash.zig");
const hmac_mod = @import("hmac.zig");
const hkdf_mod = @import("hkdf.zig");
const aead_mod = @import("aead.zig");
const pki_mod = @import("pki.zig");
const rsa_mod = @import("rsa.zig");
const kex_mod = @import("kex.zig");

pub const Sha256 = hash_mod.Sha256;
pub const Sha384 = hash_mod.Sha384;
pub const Sha512 = hash_mod.Sha512;

pub const HmacSha256 = hmac_mod.HmacSha256;
pub const HmacSha384 = hmac_mod.HmacSha384;
pub const HmacSha512 = hmac_mod.HmacSha512;

pub const HkdfSha256 = hkdf_mod.HkdfSha256;
pub const HkdfSha384 = hkdf_mod.HkdfSha384;
pub const HkdfSha512 = hkdf_mod.HkdfSha512;

pub const Aes128Gcm = aead_mod.Aes128Gcm;
pub const Aes256Gcm = aead_mod.Aes256Gcm;
pub const ChaCha20Poly1305 = aead_mod.ChaCha20Poly1305;

pub const Ed25519 = pki_mod.Ed25519;
pub const EcdsaP256Sha256 = pki_mod.EcdsaP256Sha256;
pub const EcdsaP384Sha384 = pki_mod.EcdsaP384Sha384;

pub const rsa = rsa_mod.rsa;

pub const X25519 = kex_mod.X25519;
pub const P256 = kex_mod.P256;

pub const x509 = @import("x509.zig");

const runtime_crypto_suite = @import("../../crypto/suite.zig");
pub const Crypto = runtime_crypto_suite.CryptoSuite(@This());
