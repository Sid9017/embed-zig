const std = @import("std");
const Crypto = @import("embed").runtime.std.Crypto;
const HmacSha256 = Crypto.Hmac.Sha256();
const HmacSha384 = Crypto.Hmac.Sha384();
const HmacSha512 = Crypto.Hmac.Sha512();

fn expectHex(actual: []const u8, comptime hex: []const u8) !void {
    var expected: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, hex);
    try std.testing.expectEqualSlices(u8, &expected, actual);
}

test "hmac sha256/384/512 RFC4231 case1" {
    const key = [_]u8{0x0b} ** 20;
    const data = "Hi There";

    var mac256: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac256, data, &key);
    try expectHex(&mac256, "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");

    var mac384: [HmacSha384.mac_length]u8 = undefined;
    HmacSha384.create(&mac384, data, &key);
    try expectHex(&mac384, "afd03944d84895626b0825f4ab46907f15f9dadbe4101ec682aa034c7cebc59cfaea9ea9076ede7f4af152e8b2fa9cb6");

    var mac512: [HmacSha512.mac_length]u8 = undefined;
    HmacSha512.create(&mac512, data, &key);
    try expectHex(&mac512, "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854");
}
