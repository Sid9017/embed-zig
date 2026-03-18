const std = @import("std");
const Crypto = @import("embed").runtime.std.Crypto;
const HmacSha256 = Crypto.Hmac.Sha256();

test "hmac contract with Std.Crypto" {
    const key = [_]u8{0x0b} ** 20;
    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, "Hi There", &key);
    try std.testing.expect(mac[0] != 0 or mac[1] != 0);
}
