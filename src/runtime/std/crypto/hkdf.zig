const std = @import("std");

pub const HkdfSha256 = struct {
    pub const prk_length = std.crypto.kdf.hkdf.HkdfSha256.prk_length;

    pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8 {
        return std.crypto.kdf.hkdf.HkdfSha256.extract(salt orelse &[_]u8{}, ikm);
    }

    pub fn expand(prk: *const [prk_length]u8, info: []const u8, out: []u8) void {
        std.crypto.kdf.hkdf.HkdfSha256.expand(out, info, prk.*);
    }
};

pub const HkdfSha384 = struct {
    const Inner = std.crypto.kdf.hkdf.Hkdf(std.crypto.auth.hmac.sha2.HmacSha384);
    pub const prk_length = Inner.prk_length;

    pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8 {
        return Inner.extract(salt orelse &[_]u8{}, ikm);
    }

    pub fn expand(prk: *const [prk_length]u8, info: []const u8, out: []u8) void {
        Inner.expand(out, info, prk.*);
    }
};

pub const HkdfSha512 = struct {
    pub const prk_length = std.crypto.kdf.hkdf.HkdfSha512.prk_length;

    pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8 {
        return std.crypto.kdf.hkdf.HkdfSha512.extract(salt orelse &[_]u8{}, ikm);
    }

    pub fn expand(prk: *const [prk_length]u8, info: []const u8, out: []u8) void {
        std.crypto.kdf.hkdf.HkdfSha512.expand(out, info, prk.*);
    }
};

fn expectHex(actual: []const u8, comptime hex: []const u8) !void {
    var expected: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, hex);
    try std.testing.expectEqualSlices(u8, &expected, actual);
}

test "hkdf sha256 RFC5869 test case 1" {
    const ikm = [_]u8{0x0b} ** 22;
    const salt = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c };
    const info = [_]u8{ 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9 };

    const prk = HkdfSha256.extract(&salt, &ikm);
    try expectHex(&prk, "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5");

    var okm: [42]u8 = undefined;
    HkdfSha256.expand(&prk, &info, &okm);
    try expectHex(&okm, "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865");
}
