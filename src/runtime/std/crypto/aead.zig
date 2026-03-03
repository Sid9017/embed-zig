const std = @import("std");

fn AeadWrapper(comptime StdAead: type) type {
    return struct {
        pub const key_length = StdAead.key_length;
        pub const nonce_length = StdAead.nonce_length;
        pub const tag_length = StdAead.tag_length;

        pub fn encryptStatic(
            ciphertext: []u8,
            tag: *[tag_length]u8,
            plaintext: []const u8,
            aad: []const u8,
            nonce: [nonce_length]u8,
            key: [key_length]u8,
        ) void {
            StdAead.encrypt(ciphertext[0..plaintext.len], tag, plaintext, aad, nonce, key);
        }

        pub fn decryptStatic(
            plaintext: []u8,
            ciphertext: []const u8,
            tag: [tag_length]u8,
            aad: []const u8,
            nonce: [nonce_length]u8,
            key: [key_length]u8,
        ) error{AuthenticationFailed}!void {
            StdAead.decrypt(plaintext[0..ciphertext.len], ciphertext, tag, aad, nonce, key) catch {
                return error.AuthenticationFailed;
            };
        }
    };
}

pub const Aes128Gcm = AeadWrapper(std.crypto.aead.aes_gcm.Aes128Gcm);
pub const Aes256Gcm = AeadWrapper(std.crypto.aead.aes_gcm.Aes256Gcm);
pub const ChaCha20Poly1305 = AeadWrapper(std.crypto.aead.chacha_poly.ChaCha20Poly1305);

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
