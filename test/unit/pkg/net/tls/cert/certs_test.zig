const std = @import("std");
const embed = @import("embed");

const cert = embed.pkg.net.tls.cert;

test "embedded certs are non-empty PEM" {
    const certs = [_][]const u8{
        cert.isrg_root_x1,
        cert.amazon_root_ca1,
        cert.digicert_global_root_g2,
        cert.cmn_ca_bundle,
        cert.mozilla_ca_bundle,
    };
    for (certs) |pem| {
        try std.testing.expect(pem.len > 0);
        try std.testing.expect(std.mem.startsWith(u8, pem, "-----BEGIN CERTIFICATE-----") or
            std.mem.startsWith(u8, pem, "##"));
    }
}
