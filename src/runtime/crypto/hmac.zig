//! Runtime crypto HMAC contracts.

const Seal = struct {};

pub fn Make(comptime factory: fn (comptime usize) type) type {
    return struct {
        pub const seal: Seal = .{};

        pub fn Hmac(comptime mac_len: usize) type {
            const Impl = factory(mac_len);

            comptime {
                if (!@hasDecl(Impl, "mac_length") or Impl.mac_length != mac_len) {
                    @compileError("HMAC.mac_length mismatch");
                }

                _ = @as(*const fn (*[mac_len]u8, []const u8, []const u8) void, &Impl.create);
                _ = @as(*const fn ([]const u8) Impl, &Impl.init);
                _ = @as(*const fn (*Impl, []const u8) void, &Impl.update);
                _ = @as(*const fn (*Impl) [mac_len]u8, &Impl.final);
            }

            return struct {
                pub const mac_length = mac_len;
                pub const BackendType = Impl;

                impl: Impl,

                pub fn create(out: *[mac_len]u8, msg: []const u8, key: []const u8) void {
                    Impl.create(out, msg, key);
                }

                pub fn init(key: []const u8) @This() {
                    return .{ .impl = Impl.init(key) };
                }

                pub fn update(self: *@This(), data: []const u8) void {
                    self.impl.update(data);
                }

                pub fn final(self: *@This()) [mac_len]u8 {
                    return self.impl.final();
                }
            };
        }

        pub fn Sha256() type {
            return Hmac(32);
        }

        pub fn Sha384() type {
            return Hmac(48);
        }

        pub fn Sha512() type {
            return Hmac(64);
        }
    };
}

pub fn is(comptime T: type) type {
    comptime {
        if (!@hasDecl(T, "seal") or @TypeOf(T.seal) != Seal) {
            @compileError("Impl must have pub const seal: hmac.Seal — use hmac.Make(factory) to construct");
        }
    }
    return T;
}
