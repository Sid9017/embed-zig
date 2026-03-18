const std = @import("std");
const Crypto = @import("embed").runtime.std.Crypto;
const HkdfSha256 = Crypto.Hkdf.Sha256();

test "hkdf contract with Std.Crypto" {
    const prk = HkdfSha256.extract(null, "secret");
    const out = HkdfSha256.expand(&prk, "info", 32);
    try std.testing.expect(out.len == 32);
}
