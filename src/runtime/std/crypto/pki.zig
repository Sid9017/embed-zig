const std = @import("std");

pub fn verifyEd25519(sig: []const u8, msg: []const u8, pk: []const u8) bool {
    const signature = std.crypto.sign.Ed25519.Signature.fromBytes(sig[0..64].*);
    const public_key = std.crypto.sign.Ed25519.PublicKey.fromBytes(pk[0..32].*) catch return false;
    signature.verify(msg, public_key) catch return false;
    return true;
}

pub fn verifyEcdsaP256(sig: []const u8, msg: []const u8, pk: []const u8) bool {
    const Scheme = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const signature = Scheme.Signature.fromDer(sig) catch return false;
    const public_key = Scheme.PublicKey.fromSec1(pk) catch return false;
    signature.verify(msg, public_key) catch return false;
    return true;
}

pub fn verifyEcdsaP384(sig: []const u8, msg: []const u8, pk: []const u8) bool {
    const Scheme = std.crypto.sign.ecdsa.EcdsaP384Sha384;
    const signature = Scheme.Signature.fromDer(sig) catch return false;
    const public_key = Scheme.PublicKey.fromSec1(pk) catch return false;
    signature.verify(msg, public_key) catch return false;
    return true;
}
