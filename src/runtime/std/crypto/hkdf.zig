const std = @import("std");

fn HkdfWrapper(comptime StdHkdf: type) type {
    return struct {
        pub const prk_length = StdHkdf.prk_length;

        pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8 {
            return StdHkdf.extract(salt orelse &[_]u8{}, ikm);
        }

        pub fn expand(prk: *const [prk_length]u8, info: []const u8, comptime len: usize) [len]u8 {
            var out: [len]u8 = undefined;
            StdHkdf.expand(&out, info, prk.*);
            return out;
        }
    };
}

pub fn hkdf(comptime prk_len: usize) type {
    return switch (prk_len) {
        32 => HkdfWrapper(std.crypto.kdf.hkdf.HkdfSha256),
        48 => HkdfWrapper(std.crypto.kdf.hkdf.Hkdf(std.crypto.auth.hmac.sha2.HmacSha384)),
        64 => HkdfWrapper(std.crypto.kdf.hkdf.HkdfSha512),
        else => @compileError("unsupported hkdf prk length"),
    };
}
