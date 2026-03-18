const std = @import("std");
const embed = @import("embed");
const Crypto = embed.runtime.std.Crypto;

test "CaStore initSystem loads certificates" {
    var store = Crypto.X509.init(std.testing.allocator) catch return;
    defer store.deinit();

    try std.testing.expect(store.impl.bundle.bytes.items.len > 0);
}

test "verifyChain rejects empty chain" {
    var store = Crypto.X509.init(std.testing.allocator) catch return;
    defer store.deinit();

    const empty: []const []const u8 = &.{};
    try std.testing.expectError(error.CertificateChainTooShort, store.verifyChain(empty, null, 0));
}

test "verifyChain rejects garbage DER" {
    var store = Crypto.X509.init(std.testing.allocator) catch return;
    defer store.deinit();

    const garbage = [_]u8{0xFF} ** 32;
    const chain: []const []const u8 = &.{&garbage};
    try std.testing.expectError(error.CertificateParseError, store.verifyChain(chain, null, 0));
}
