//! Runtime crypto AEAD contracts.

pub fn from(comptime Impl: type, comptime key_len: usize, comptime nonce_len: usize, comptime tag_len: usize) type {
    comptime {
        if (!@hasDecl(Impl, "key_length") or Impl.key_length != key_len) {
            @compileError("AEAD.key_length mismatch");
        }
        if (!@hasDecl(Impl, "nonce_length") or Impl.nonce_length != nonce_len) {
            @compileError("AEAD.nonce_length mismatch");
        }
        if (!@hasDecl(Impl, "tag_length") or Impl.tag_length != tag_len) {
            @compileError("AEAD.tag_length mismatch");
        }

        _ = @as(
            *const fn ([]u8, *[tag_len]u8, []const u8, []const u8, [nonce_len]u8, [key_len]u8) void,
            &Impl.encryptStatic,
        );
        _ = @as(
            *const fn ([]u8, []const u8, [tag_len]u8, []const u8, [nonce_len]u8, [key_len]u8) error{AuthenticationFailed}!void,
            &Impl.decryptStatic,
        );
    }
    return Impl;
}

pub fn Aes128Gcm(comptime Impl: type) type {
    return from(Impl, 16, 12, 16);
}

pub fn Aes256Gcm(comptime Impl: type) type {
    return from(Impl, 32, 12, 16);
}

pub fn ChaCha20Poly1305(comptime Impl: type) type {
    return from(Impl, 32, 12, 16);
}
