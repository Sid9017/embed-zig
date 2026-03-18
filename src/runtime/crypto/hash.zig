//! Runtime crypto hash contracts.

const Seal = struct {};

pub fn Make(comptime factory: fn (comptime usize) type) type {
    return struct {
        pub const seal: Seal = .{};

        pub fn Hash(comptime digest_len: usize) type {
            const Impl = factory(digest_len);

            comptime {
                if (!@hasDecl(Impl, "digest_length") or Impl.digest_length != digest_len) {
                    @compileError("Hash.digest_length mismatch");
                }

                _ = @as(*const fn () Impl, &Impl.init);
                _ = @as(*const fn (*Impl, []const u8) void, &Impl.update);
                _ = @as(*const fn (*Impl) [digest_len]u8, &Impl.final);
                _ = @as(*const fn ([]const u8, *[digest_len]u8) void, &Impl.hash);
            }

            return struct {
                pub const digest_length = digest_len;
                pub const BackendType = Impl;

                impl: Impl,

                pub fn init() @This() {
                    return .{ .impl = Impl.init() };
                }

                pub fn update(self: *@This(), data: []const u8) void {
                    self.impl.update(data);
                }

                pub fn final(self: *@This()) [digest_len]u8 {
                    return self.impl.final();
                }

                pub fn hash(data: []const u8, out: *[digest_len]u8) void {
                    Impl.hash(data, out);
                }
            };
        }

        pub fn Sha256() type {
            return Hash(32);
        }

        pub fn Sha384() type {
            return Hash(48);
        }

        pub fn Sha512() type {
            return Hash(64);
        }
    };
}

pub fn is(comptime T: type) type {
    comptime {
        if (!@hasDecl(T, "seal") or @TypeOf(T.seal) != Seal) {
            @compileError("Impl must have pub const seal: hash.Seal — use hash.Make(factory) to construct");
        }
    }
    return T;
}
