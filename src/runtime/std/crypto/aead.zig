const std = @import("std");

pub fn AeadWrapper(comptime StdAead: type) type {
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
