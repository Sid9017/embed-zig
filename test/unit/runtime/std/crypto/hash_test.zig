const std = @import("std");
const Crypto = @import("embed").runtime.std.Crypto;
const Sha256 = Crypto.Hash.Sha256();
const Sha384 = Crypto.Hash.Sha384();
const Sha512 = Crypto.Hash.Sha512();

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
