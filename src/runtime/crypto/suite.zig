//! Runtime crypto suite contract.

const hash = @import("hash.zig");
const hmac = @import("hmac.zig");
const hkdf = @import("hkdf.zig");
const aead = @import("aead.zig");
const pki = @import("pki.zig");
const x25519 = @import("x25519.zig");
const p256 = @import("p256.zig");
const rsa = @import("rsa.zig");
const x509 = @import("x509.zig");

pub const Seal = struct {};

/// Construct a sealed CryptoSuite from a backend Impl type.
///
/// Impl must provide:
/// - factories: `hash`, `hmac`, `hkdf`, `aead`
/// - type constructors: `pki`, `rsa`, `x509`
/// - raw types: `X25519`, `P256`
pub fn Make(comptime Impl: type) type {
    return struct {
        pub const seal: Seal = .{};

        pub const Hash = hash.Make(Impl.hash);
        pub const Hmac = hmac.Make(Impl.hmac);
        pub const Hkdf = hkdf.Make(Impl.hkdf);
        pub const Aead = aead.Make(Impl.aead);
        pub const Pki = pki.Make(Impl.pki);
        pub const Rsa = rsa.Make(Impl.rsa);
        pub const X509 = x509.Make(Impl.X509);
        pub const X25519 = x25519.Make(Impl.X25519);
        pub const P256 = p256.Make(Impl.P256);
    };
}

/// Validate that Impl has been sealed via Make().
pub fn is(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "seal") or @TypeOf(Impl.seal) != Seal) {
            @compileError("Impl must have pub const seal: suite.Seal — use suite.Make(Backend) to construct");
        }
    }

    return Impl;
}
