//! Runtime crypto HKDF contracts.

const Seal = struct {};

pub fn Make(comptime factory: fn (comptime usize) type) type {
    return struct {
        pub const seal: Seal = .{};

        pub fn Hkdf(comptime prk_len: usize) type {
            const Impl = factory(prk_len);

            comptime {
                if (!@hasDecl(Impl, "prk_length") or Impl.prk_length != prk_len) {
                    @compileError("HKDF.prk_length mismatch");
                }

                _ = @as(*const fn (?[]const u8, []const u8) [prk_len]u8, &Impl.extract);

                if (!@hasDecl(Impl, "expand")) {
                    @compileError("HKDF missing expand");
                }
            }

            return struct {
                pub const prk_length = prk_len;
                pub const BackendType = Impl;

                pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_len]u8 {
                    return Impl.extract(salt, ikm);
                }

                pub fn expand(prk: *const [prk_len]u8, ctx: []const u8, comptime len: usize) [len]u8 {
                    return Impl.expand(prk, ctx, len);
                }
            };
        }

        pub fn Sha256() type {
            return Hkdf(32);
        }

        pub fn Sha384() type {
            return Hkdf(48);
        }

        pub fn Sha512() type {
            return Hkdf(64);
        }
    };
}

pub fn is(comptime T: type) type {
    comptime {
        if (!@hasDecl(T, "seal") or @TypeOf(T.seal) != Seal) {
            @compileError("Impl must have pub const seal: hkdf.Seal — use hkdf.Make(factory) to construct");
        }
    }
    return T;
}
