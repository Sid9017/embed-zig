const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const extensions = embed.pkg.net.tls.extensions;
const tls_common = embed.pkg.net.tls.common;

test "ExtensionBuilder server name" {
    var buf: [256]u8 = undefined;
    var builder = extensions.ExtensionBuilder.init(&buf);

    try builder.addServerName("example.com");

    const data = builder.getData();
    try std.testing.expect(data.len > 0);

    const ext_type = std.mem.readInt(u16, data[0..2], .big);
    try std.testing.expectEqual(@as(u16, 0), ext_type);
}

test "ExtensionBuilder supported versions" {
    var buf: [256]u8 = undefined;
    var builder = extensions.ExtensionBuilder.init(&buf);

    const versions = [_]tls_common.ProtocolVersion{ .tls_1_3, .tls_1_2 };
    try builder.addSupportedVersions(&versions);

    const data = builder.getData();
    try std.testing.expect(data.len > 0);
}

test "parseServerName" {
    var buf: [256]u8 = undefined;
    var builder = extensions.ExtensionBuilder.init(&buf);
    try builder.addServerName("test.example.com");

    const ext_data = builder.getData()[4..];
    const hostname = try extensions.parseServerName(ext_data);
    try std.testing.expectEqualStrings("test.example.com", hostname.?);
}

test "ExtensionBuilder buffer overflow" {
    var buf: [4]u8 = undefined;
    var builder = extensions.ExtensionBuilder.init(&buf);
    try std.testing.expectError(error.BufferTooSmall, builder.addServerName("this-hostname-is-way-too-long-for-a-4-byte-buffer.example.com"));
}

test "ExtensionBuilder addSupportedGroups" {
    var buf: [256]u8 = undefined;
    var builder = extensions.ExtensionBuilder.init(&buf);

    const groups = [_]tls_common.NamedGroup{ .x25519, .secp256r1 };
    try builder.addSupportedGroups(&groups);

    const data = builder.getData();
    try std.testing.expect(data.len > 0);

    const ext_type = std.mem.readInt(u16, data[0..2], .big);
    try std.testing.expectEqual(@as(u16, @intFromEnum(tls_common.ExtensionType.supported_groups)), ext_type);
}

test "ExtensionBuilder addSignatureAlgorithms" {
    var buf: [256]u8 = undefined;
    var builder = extensions.ExtensionBuilder.init(&buf);

    const sig_algs = [_]tls_common.SignatureScheme{
        .ecdsa_secp256r1_sha256,
        .rsa_pss_rsae_sha256,
    };
    try builder.addSignatureAlgorithms(&sig_algs);

    const data = builder.getData();
    try std.testing.expect(data.len > 0);

    const ext_type = std.mem.readInt(u16, data[0..2], .big);
    try std.testing.expectEqual(@as(u16, @intFromEnum(tls_common.ExtensionType.signature_algorithms)), ext_type);
}

test "parseSupportedVersion" {
    var data: [2]u8 = undefined;
    std.mem.writeInt(u16, &data, @intFromEnum(tls_common.ProtocolVersion.tls_1_3), .big);
    const version = try extensions.parseSupportedVersion(&data);
    try std.testing.expectEqual(tls_common.ProtocolVersion.tls_1_3, version);
}

test "parseSupportedVersion too small" {
    const data: [1]u8 = .{0};
    try std.testing.expectError(error.InvalidExtension, extensions.parseSupportedVersion(&data));
}

test "parseKeyShareServer" {
    var data: [36]u8 = undefined;
    std.mem.writeInt(u16, data[0..2], @intFromEnum(tls_common.NamedGroup.x25519), .big);
    std.mem.writeInt(u16, data[2..4], 32, .big);
    @memset(data[4..36], 0xAA);

    const entry = try extensions.parseKeyShareServer(&data);
    try std.testing.expectEqual(tls_common.NamedGroup.x25519, entry.group);
    try std.testing.expectEqual(@as(usize, 32), entry.key_exchange.len);
}

test "parseKeyShareServer too small header" {
    const data: [3]u8 = .{ 0, 0, 0 };
    try std.testing.expectError(error.InvalidExtension, extensions.parseKeyShareServer(&data));
}

test "parseKeyShareServer truncated key data" {
    var data: [6]u8 = undefined;
    std.mem.writeInt(u16, data[0..2], @intFromEnum(tls_common.NamedGroup.x25519), .big);
    std.mem.writeInt(u16, data[2..4], 32, .big);
    try std.testing.expectError(error.InvalidExtension, extensions.parseKeyShareServer(&data));
}

test "ExtensionBuilder multiple extensions" {
    var buf: [512]u8 = undefined;
    var builder = extensions.ExtensionBuilder.init(&buf);

    try builder.addServerName("example.com");
    const after_sni = builder.getData().len;

    const versions = [_]tls_common.ProtocolVersion{ .tls_1_3, .tls_1_2 };
    try builder.addSupportedVersions(&versions);
    const after_versions = builder.getData().len;

    try std.testing.expect(after_versions > after_sni);
}

test "parseServerName too short data" {
    const data: [2]u8 = .{ 0, 0 };
    try std.testing.expectError(error.InvalidExtension, extensions.parseServerName(&data));
}

test "parseServerName empty list" {
    var data: [5]u8 = undefined;
    std.mem.writeInt(u16, data[0..2], 3, .big);
    data[2] = 0;
    std.mem.writeInt(u16, data[3..5], 0, .big);
    const result = try extensions.parseServerName(&data);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.len);
}

test "ExtensionBuilder addPskKeyExchangeModes" {
    var buf: [256]u8 = undefined;
    var builder = extensions.ExtensionBuilder.init(&buf);

    const modes = [_]tls_common.PskKeyExchangeMode{.psk_dhe_ke};
    try builder.addPskKeyExchangeModes(&modes);

    const data = builder.getData();
    try std.testing.expect(data.len > 0);

    const ext_type = std.mem.readInt(u16, data[0..2], .big);
    try std.testing.expectEqual(@as(u16, @intFromEnum(tls_common.ExtensionType.psk_key_exchange_modes)), ext_type);
}
