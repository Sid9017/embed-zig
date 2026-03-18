const std = @import("std");
const Crypto = @import("embed").runtime.std.Crypto;
const Aes128Gcm = Crypto.Aead.Aes128Gcm();
const ChaCha20Poly1305 = Crypto.Aead.ChaCha20Poly1305();

test "aead aes128gcm roundtrip" {
    const key: [16]u8 = [_]u8{0x11} ** 16;
    const nonce: [12]u8 = [_]u8{0x22} ** 12;
    const plaintext = "hello";
    const aad = "aad";

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    Aes128Gcm.encryptStatic(&ciphertext, &tag, plaintext, aad, nonce, key);

    var decrypted: [plaintext.len]u8 = undefined;
    try Aes128Gcm.decryptStatic(&decrypted, &ciphertext, tag, aad, nonce, key);
    try std.testing.expectEqualStrings(plaintext, &decrypted);
}

test "aead chacha20poly1305 authentication failure" {
    const key: [32]u8 = [_]u8{0x41} ** 32;
    const nonce: [12]u8 = [_]u8{0x24} ** 12;
    const plaintext = "authenticated";
    const aad = "aad";

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [ChaCha20Poly1305.tag_length]u8 = undefined;
    ChaCha20Poly1305.encryptStatic(&ciphertext, &tag, plaintext, aad, nonce, key);

    var bad_tag = tag;
    bad_tag[0] ^= 0xff;

    var out: [plaintext.len]u8 = undefined;
    try std.testing.expectError(
        error.AuthenticationFailed,
        ChaCha20Poly1305.decryptStatic(&out, &ciphertext, bad_tag, aad, nonce, key),
    );
}
