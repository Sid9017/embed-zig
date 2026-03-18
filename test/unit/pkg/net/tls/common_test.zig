const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const common = embed.pkg.net.tls.common;

test "CipherSuite properties" {
    const suite = common.CipherSuite.TLS_AES_128_GCM_SHA256;
    try std.testing.expect(suite.isTls13());
    try std.testing.expectEqual(@as(u8, 16), suite.keyLength());
    try std.testing.expectEqual(@as(u8, 12), suite.ivLength());
}

test "ProtocolVersion names" {
    try std.testing.expectEqualStrings("TLS 1.3", common.ProtocolVersion.tls_1_3.name());
    try std.testing.expectEqualStrings("TLS 1.2", common.ProtocolVersion.tls_1_2.name());
    try std.testing.expectEqualStrings("TLS 1.1", common.ProtocolVersion.tls_1_1.name());
    try std.testing.expectEqualStrings("TLS 1.0", common.ProtocolVersion.tls_1_0.name());
}

test "CipherSuite TLS 1.3 suites" {
    const tls13_suites = [_]common.CipherSuite{
        .TLS_AES_128_GCM_SHA256,
        .TLS_AES_256_GCM_SHA384,
        .TLS_CHACHA20_POLY1305_SHA256,
    };
    for (tls13_suites) |s| {
        try std.testing.expect(s.isTls13());
    }
}

test "CipherSuite TLS 1.2 suites are not TLS 1.3" {
    const tls12_suites = [_]common.CipherSuite{
        .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
        .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
        .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
        .TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
        .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
        .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
    };
    for (tls12_suites) |s| {
        try std.testing.expect(!s.isTls13());
    }
}

test "CipherSuite key/iv/tag lengths for all suites" {
    const Suite = struct { suite: common.CipherSuite, key: u8, iv: u8 };
    const cases = [_]Suite{
        .{ .suite = .TLS_AES_128_GCM_SHA256, .key = 16, .iv = 12 },
        .{ .suite = .TLS_AES_256_GCM_SHA384, .key = 32, .iv = 12 },
        .{ .suite = .TLS_CHACHA20_POLY1305_SHA256, .key = 32, .iv = 12 },
        .{ .suite = .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, .key = 16, .iv = 12 },
        .{ .suite = .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384, .key = 32, .iv = 12 },
        .{ .suite = .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256, .key = 32, .iv = 12 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.key, c.suite.keyLength());
        try std.testing.expectEqual(c.iv, c.suite.ivLength());
        try std.testing.expectEqual(@as(u8, 16), c.suite.tagLength());
    }
}

test "CipherSuite unknown suite returns zero lengths" {
    const unknown: common.CipherSuite = @enumFromInt(0xFFFF);
    try std.testing.expect(!unknown.isTls13());
    try std.testing.expectEqual(@as(u8, 0), unknown.keyLength());
    try std.testing.expectEqual(@as(u8, 0), unknown.ivLength());
}

test "ProtocolVersion enum values" {
    try std.testing.expectEqual(@as(u16, 0x0301), @intFromEnum(common.ProtocolVersion.tls_1_0));
    try std.testing.expectEqual(@as(u16, 0x0302), @intFromEnum(common.ProtocolVersion.tls_1_1));
    try std.testing.expectEqual(@as(u16, 0x0303), @intFromEnum(common.ProtocolVersion.tls_1_2));
    try std.testing.expectEqual(@as(u16, 0x0304), @intFromEnum(common.ProtocolVersion.tls_1_3));
}

test "ContentType enum values" {
    try std.testing.expectEqual(@as(u8, 20), @intFromEnum(common.ContentType.change_cipher_spec));
    try std.testing.expectEqual(@as(u8, 21), @intFromEnum(common.ContentType.alert));
    try std.testing.expectEqual(@as(u8, 22), @intFromEnum(common.ContentType.handshake));
    try std.testing.expectEqual(@as(u8, 23), @intFromEnum(common.ContentType.application_data));
}

test "MAX_PLAINTEXT_LEN and MAX_CIPHERTEXT_LEN" {
    try std.testing.expectEqual(@as(usize, 16384), common.MAX_PLAINTEXT_LEN);
    try std.testing.expect(common.MAX_CIPHERTEXT_LEN > common.MAX_PLAINTEXT_LEN);
    try std.testing.expectEqual(@as(usize, 5), common.RECORD_HEADER_LEN);
}

test "AlertLevel and common.AlertDescription values" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(common.AlertLevel.warning));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(common.AlertLevel.fatal));
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(common.AlertDescription.close_notify));
    try std.testing.expectEqual(@as(u8, 40), @intFromEnum(common.AlertDescription.handshake_failure));
}

test "NamedGroup enum values" {
    try std.testing.expectEqual(@as(u16, 29), @intFromEnum(common.NamedGroup.x25519));
    try std.testing.expectEqual(@as(u16, 23), @intFromEnum(common.NamedGroup.secp256r1));
}

test "SignatureScheme enum values" {
    try std.testing.expectEqual(@as(u16, 0x0403), @intFromEnum(common.SignatureScheme.ecdsa_secp256r1_sha256));
    try std.testing.expectEqual(@as(u16, 0x0804), @intFromEnum(common.SignatureScheme.rsa_pss_rsae_sha256));
}

test "ExtensionType enum values" {
    try std.testing.expectEqual(@as(u16, 0), @intFromEnum(common.ExtensionType.server_name));
    try std.testing.expectEqual(@as(u16, 43), @intFromEnum(common.ExtensionType.supported_versions));
    try std.testing.expectEqual(@as(u16, 51), @intFromEnum(common.ExtensionType.key_share));
}
