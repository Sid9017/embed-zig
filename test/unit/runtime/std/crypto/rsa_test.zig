const std = @import("std");
const embed = @import("embed");
const Crypto = embed.runtime.std.Crypto;

test "rsa sealed type exposes verify functions" {
    try std.testing.expect(@hasDecl(Crypto.Rsa, "verifyPKCS1v1_5"));
    try std.testing.expect(@hasDecl(Crypto.Rsa, "verifyPSS"));
    try std.testing.expect(@hasDecl(Crypto.Rsa, "parseDer"));
}
