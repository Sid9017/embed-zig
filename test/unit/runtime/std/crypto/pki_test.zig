const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const EcdsaP256Sha256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const EcdsaP384Sha384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;

test "pki ed25519 sign/verify" {
    const msg = "pki-ed25519-msg";
    const bad = "pki-ed25519-msg-bad";

    const seed: [Ed25519.KeyPair.seed_length]u8 = [_]u8{0x42} ** Ed25519.KeyPair.seed_length;
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);

    const sig = try kp.sign(msg, null);
    sig.verify(msg, kp.public_key) catch return error.TestUnexpectedResult;
    if (sig.verify(bad, kp.public_key)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "pki ecdsa p256 sign/verify" {
    const msg = "pki-ecdsa-p256";
    const bad = "pki-ecdsa-p256-bad";

    const seed: [EcdsaP256Sha256.KeyPair.seed_length]u8 = [_]u8{0x23} ** EcdsaP256Sha256.KeyPair.seed_length;
    const kp = try EcdsaP256Sha256.KeyPair.generateDeterministic(seed);

    const sig = try kp.sign(msg, null);
    sig.verify(msg, kp.public_key) catch return error.TestUnexpectedResult;
    if (sig.verify(bad, kp.public_key)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "pki ecdsa p384 sign/verify" {
    const msg = "pki-ecdsa-p384";
    const bad = "pki-ecdsa-p384-bad";

    const seed: [EcdsaP384Sha384.KeyPair.seed_length]u8 = [_]u8{0x37} ** EcdsaP384Sha384.KeyPair.seed_length;
    const kp = try EcdsaP384Sha384.KeyPair.generateDeterministic(seed);

    const sig = try kp.sign(msg, null);
    sig.verify(msg, kp.public_key) catch return error.TestUnexpectedResult;
    if (sig.verify(bad, kp.public_key)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}
