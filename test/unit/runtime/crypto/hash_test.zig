const std = @import("std");
const Crypto = @import("embed").runtime.std.Crypto;
const Sha256 = Crypto.Hash.Sha256();

test "hash contract with Std.Crypto" {
    var out: [32]u8 = undefined;
    Sha256.hash("abc", &out);
    try std.testing.expect(out[0] != 0 or out[1] != 0);
}
