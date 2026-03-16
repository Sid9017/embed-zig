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

/// Aes256Gcm and ChaCha20Poly1305 share (32, 12, 16) — the contract's
/// convenience methods both resolve to the same factory call, so we pick
/// one canonical backend (Aes256Gcm) for that parameter triple.
pub fn aead(comptime key_len: usize, comptime nonce_len: usize, comptime tag_len: usize) type {
    if (nonce_len != 12 or tag_len != 16) @compileError("unsupported aead nonce/tag length");
    return switch (key_len) {
        16 => AeadWrapper(std.crypto.aead.aes_gcm.Aes128Gcm),
        32 => AeadWrapper(std.crypto.aead.aes_gcm.Aes256Gcm),
        else => @compileError("unsupported aead key length"),
    };
}
