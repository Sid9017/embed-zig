const std = @import("std");

pub const Ed25519 = struct {
    pub const Signature = std.crypto.sign.Ed25519.Signature;
    pub const PublicKey = std.crypto.sign.Ed25519.PublicKey;
    pub const SecretKey = std.crypto.sign.Ed25519.SecretKey;
    pub const KeyPair = std.crypto.sign.Ed25519.KeyPair;

    pub fn sign(key_pair: KeyPair, msg: []const u8, noise: ?[KeyPair.seed_length]u8) !Signature {
        return key_pair.sign(msg, noise);
    }

    pub fn verify(sig: Signature, msg: []const u8, pk: PublicKey) bool {
        sig.verify(msg, pk) catch return false;
        return true;
    }
};

pub const EcdsaP256Sha256 = struct {
    const Scheme = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    pub const Signature = Scheme.Signature;
    pub const PublicKey = Scheme.PublicKey;
    pub const SecretKey = Scheme.SecretKey;
    pub const KeyPair = Scheme.KeyPair;

    pub fn sign(key_pair: KeyPair, msg: []const u8, noise: ?[KeyPair.seed_length]u8) !Signature {
        return key_pair.sign(msg, noise);
    }

    pub fn verify(sig: Signature, msg: []const u8, pk: PublicKey) bool {
        sig.verify(msg, pk) catch return false;
        return true;
    }
};

pub const EcdsaP384Sha384 = struct {
    const Scheme = std.crypto.sign.ecdsa.EcdsaP384Sha384;
    pub const Signature = Scheme.Signature;
    pub const PublicKey = Scheme.PublicKey;
    pub const SecretKey = Scheme.SecretKey;
    pub const KeyPair = Scheme.KeyPair;

    pub fn sign(key_pair: KeyPair, msg: []const u8, noise: ?[KeyPair.seed_length]u8) !Signature {
        return key_pair.sign(msg, noise);
    }

    pub fn verify(sig: Signature, msg: []const u8, pk: PublicKey) bool {
        sig.verify(msg, pk) catch return false;
        return true;
    }
};

test "pki ed25519 sign/verify" {
    const msg = "pki-ed25519-msg";
    const bad = "pki-ed25519-msg-bad";

    const seed: [Ed25519.KeyPair.seed_length]u8 = [_]u8{0x42} ** Ed25519.KeyPair.seed_length;
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);

    const sig = try Ed25519.sign(kp, msg, null);
    try std.testing.expect(Ed25519.verify(sig, msg, kp.public_key));
    try std.testing.expect(!Ed25519.verify(sig, bad, kp.public_key));
}

test "pki ecdsa p256 sign/verify" {
    const msg = "pki-ecdsa-p256";
    const bad = "pki-ecdsa-p256-bad";

    const seed: [EcdsaP256Sha256.KeyPair.seed_length]u8 = [_]u8{0x23} ** EcdsaP256Sha256.KeyPair.seed_length;
    const kp = try EcdsaP256Sha256.KeyPair.generateDeterministic(seed);

    const sig = try EcdsaP256Sha256.sign(kp, msg, null);
    try std.testing.expect(EcdsaP256Sha256.verify(sig, msg, kp.public_key));
    try std.testing.expect(!EcdsaP256Sha256.verify(sig, bad, kp.public_key));
}

test "pki ecdsa p384 sign/verify" {
    const msg = "pki-ecdsa-p384";
    const bad = "pki-ecdsa-p384-bad";

    const seed: [EcdsaP384Sha384.KeyPair.seed_length]u8 = [_]u8{0x37} ** EcdsaP384Sha384.KeyPair.seed_length;
    const kp = try EcdsaP384Sha384.KeyPair.generateDeterministic(seed);

    const sig = try EcdsaP384Sha384.sign(kp, msg, null);
    try std.testing.expect(EcdsaP384Sha384.verify(sig, msg, kp.public_key));
    try std.testing.expect(!EcdsaP384Sha384.verify(sig, bad, kp.public_key));
}
