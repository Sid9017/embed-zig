//! Runtime crypto AEAD contracts.

const Seal = struct {};

pub fn Make(comptime factory: fn (comptime usize, comptime usize, comptime usize) type) type {
    return struct {
        pub const seal: Seal = .{};

        pub fn Aead(comptime key_len: usize, comptime nonce_len: usize, comptime tag_len: usize) type {
            const Impl = factory(key_len, nonce_len, tag_len);

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

            return struct {
                pub const key_length = key_len;
                pub const nonce_length = nonce_len;
                pub const tag_length = tag_len;
                pub const BackendType = Impl;

                pub fn encryptStatic(
                    buf: []u8,
                    tag: *[tag_len]u8,
                    plaintext: []const u8,
                    ad: []const u8,
                    nonce: [nonce_len]u8,
                    key: [key_len]u8,
                ) void {
                    Impl.encryptStatic(buf, tag, plaintext, ad, nonce, key);
                }

                pub fn decryptStatic(
                    buf: []u8,
                    ciphertext: []const u8,
                    tag: [tag_len]u8,
                    ad: []const u8,
                    nonce: [nonce_len]u8,
                    key: [key_len]u8,
                ) error{AuthenticationFailed}!void {
                    return Impl.decryptStatic(buf, ciphertext, tag, ad, nonce, key);
                }
            };
        }

        pub fn Aes128Gcm() type {
            return Aead(16, 12, 16);
        }

        pub fn Aes256Gcm() type {
            return Aead(32, 12, 16);
        }

        pub fn ChaCha20Poly1305() type {
            return Aead(32, 12, 16);
        }
    };
}

pub fn is(comptime T: type) type {
    comptime {
        if (!@hasDecl(T, "seal") or @TypeOf(T.seal) != Seal) {
            @compileError("Impl must have pub const seal: aead.Seal — use aead.Make(factory) to construct");
        }
    }
    return T;
}
