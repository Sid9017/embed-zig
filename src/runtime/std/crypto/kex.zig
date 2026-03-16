const std = @import("std");
const x25519_contract = @import("../../crypto/x25519.zig");

pub const X25519 = struct {
    pub fn generateDeterministic(seed: [32]u8) anyerror!x25519_contract.KeyPair {
        const kp = std.crypto.dh.X25519.KeyPair.generateDeterministic(seed) catch |e| return e;
        return .{
            .public_key = kp.public_key,
            .secret_key = kp.secret_key,
        };
    }

    pub fn scalarmult(secret: [32]u8, public: [32]u8) anyerror![32]u8 {
        return std.crypto.dh.X25519.scalarmult(secret, public) catch |e| return e;
    }
};

pub const P256 = struct {
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

    pub fn computePublicKey(secret_key: [32]u8) anyerror![65]u8 {
        const kp = Ecdsa.KeyPair.generateDeterministic(secret_key) catch |e| return e;
        return kp.public_key.toUncompressedSec1();
    }

    pub fn ecdh(secret_key: [32]u8, peer_public: [65]u8) anyerror![32]u8 {
        const pk = Ecdsa.PublicKey.fromSec1(&peer_public) catch return error.IdentityElement;
        const mul = pk.p.mulPublic(secret_key, .big) catch return error.IdentityElement;
        return mul.affineCoordinates().x.toBytes(.big);
    }
};
