//! Runtime crypto HKDF contracts.

/// Generic HKDF contract validator.
pub fn from(comptime Impl: type, comptime prk_len: usize) type {
    comptime {
        if (!@hasDecl(Impl, "prk_length") or Impl.prk_length != prk_len) {
            @compileError("HKDF.prk_length mismatch");
        }

        _ = @as(*const fn (?[]const u8, []const u8) [prk_len]u8, &Impl.extract);
        _ = @as(*const fn (*const [prk_len]u8, []const u8, []u8) void, &Impl.expand);
    }
    return Impl;
}

pub fn Sha256(comptime Impl: type) type {
    return from(Impl, 32);
}

pub fn Sha384(comptime Impl: type) type {
    return from(Impl, 48);
}

pub fn Sha512(comptime Impl: type) type {
    return from(Impl, 64);
}

test "hkdf contract with mock" {
    const MockHkdf = struct {
        pub const prk_length = 32;

        pub fn extract(_: ?[]const u8, _: []const u8) [32]u8 {
            return [_]u8{3} ** 32;
        }

        pub fn expand(_: *const [32]u8, _: []const u8, out: []u8) void {
            @memset(out, 0x33);
        }
    };

    const H = Sha256(MockHkdf);
    _ = H;
}
