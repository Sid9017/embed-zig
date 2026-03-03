const std = @import("std");

fn HashWrapper(comptime StdHash: type) type {
    return struct {
        pub const digest_length = StdHash.digest_length;

        inner: StdHash,

        pub fn init() @This() {
            return .{ .inner = StdHash.init(.{}) };
        }

        pub fn update(self: *@This(), data: []const u8) void {
            self.inner.update(data);
        }

        pub fn final(self: *@This()) [digest_length]u8 {
            var out: [digest_length]u8 = undefined;
            self.inner.final(&out);
            return out;
        }

        pub fn hash(data: []const u8, out: *[digest_length]u8) void {
            StdHash.hash(data, out, .{});
        }
    };
}

pub const Sha256 = HashWrapper(std.crypto.hash.sha2.Sha256);
pub const Sha384 = HashWrapper(std.crypto.hash.sha2.Sha384);
pub const Sha512 = HashWrapper(std.crypto.hash.sha2.Sha512);

fn expectHex(actual: []const u8, comptime hex: []const u8) !void {
    var expected: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, hex);
    try std.testing.expectEqualSlices(u8, &expected, actual);
}

test "sha256 vector abc" {
    var out: [32]u8 = undefined;
    Sha256.hash("abc", &out);
    try expectHex(&out, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

test "sha384 vector abc" {
    var out: [48]u8 = undefined;
    Sha384.hash("abc", &out);
    try expectHex(&out, "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7");
}

test "sha512 vector abc" {
    var out: [64]u8 = undefined;
    Sha512.hash("abc", &out);
    try expectHex(&out, "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f");
}
