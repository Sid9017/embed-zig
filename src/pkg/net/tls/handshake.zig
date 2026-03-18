const std = @import("std");
const embed = @import("../../../mod.zig");
const runtime_suite = embed.runtime;
const common = @import("common.zig");
const extensions = @import("extensions.zig");
const record = @import("record.zig");
const kdf = @import("kdf.zig");

const HandshakeType = common.HandshakeType;
const ProtocolVersion = common.ProtocolVersion;
const CipherSuite = common.CipherSuite;
const NamedGroup = common.NamedGroup;
const SignatureScheme = common.SignatureScheme;
const ContentType = common.ContentType;

pub const HandshakeHeader = struct {
    msg_type: HandshakeType,
    length: u24,

    pub const SIZE = 4;

    pub fn parse(buf: []const u8) !HandshakeHeader {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return HandshakeHeader{
            .msg_type = @enumFromInt(buf[0]),
            .length = std.mem.readInt(u24, buf[1..4], .big),
        };
    }

    pub fn serialize(self: HandshakeHeader, buf: []u8) !void {
        if (buf.len < SIZE) return error.BufferTooSmall;
        buf[0] = @intFromEnum(self.msg_type);
        std.mem.writeInt(u24, buf[1..4], self.length, .big);
    }
};

pub fn KeyExchange(comptime Runtime: type) type {
    comptime {
        _ = runtime_suite.is(Runtime);
    }
    return union(enum) {
        x25519: X25519KeyExchange(Runtime),
        secp256r1: P256KeyExchange(Runtime),

        const Self = @This();

        pub fn generate(group: NamedGroup, rng: Runtime.Rng) !Self {
            return switch (group) {
                .x25519 => .{ .x25519 = try X25519KeyExchange(Runtime).generate(rng) },
                .secp256r1 => .{ .secp256r1 = try P256KeyExchange(Runtime).generate(rng) },
                else => error.UnsupportedGroup,
            };
        }

        pub fn publicKey(self: *const Self) []const u8 {
            return switch (self.*) {
                .x25519 => |*kx| &kx.public_key,
                .secp256r1 => |*kx| &kx.public_key,
            };
        }

        pub fn computeSharedSecret(self: *Self, peer_public: []const u8) ![]const u8 {
            return switch (self.*) {
                .x25519 => |*kx| try kx.computeSharedSecret(peer_public),
                .secp256r1 => |*kx| try kx.computeSharedSecret(peer_public),
            };
        }
    };
}

pub fn X25519KeyExchange(comptime Runtime: type) type {
    comptime {
        _ = runtime_suite.is(Runtime);
    }
    return struct {
        secret_key: [32]u8,
        public_key: [32]u8,
        shared_secret: [32]u8,

        const Self = @This();

        pub fn generate(rng: Runtime.Rng) !Self {
            var self = Self{
                .secret_key = [_]u8{0} ** 32,
                .public_key = [_]u8{0} ** 32,
                .shared_secret = [_]u8{0} ** 32,
            };
            try rng.fill(&self.secret_key);
            const kp = try Runtime.Crypto.X25519.generateDeterministic(self.secret_key);
            self.public_key = kp.public_key;
            return self;
        }

        pub fn computeSharedSecret(self: *Self, peer_public: []const u8) ![]const u8 {
            if (peer_public.len != 32) return error.InvalidPublicKey;
            self.shared_secret = try Runtime.Crypto.X25519.scalarmult(
                self.secret_key,
                peer_public[0..32].*,
            );
            return &self.shared_secret;
        }
    };
}

pub fn P256KeyExchange(comptime Runtime: type) type {
    comptime {
        _ = runtime_suite.is(Runtime);
    }
    return struct {
        secret_key: [32]u8,
        public_key: [65]u8,
        shared_secret: [32]u8,

        const Self = @This();

        pub fn generate(rng: Runtime.Rng) !Self {
            var self = Self{
                .secret_key = [_]u8{0} ** 32,
                .public_key = [_]u8{0} ** 65,
                .shared_secret = [_]u8{0} ** 32,
            };
            try rng.fill(&self.secret_key);

            self.public_key = Runtime.Crypto.P256.computePublicKey(self.secret_key) catch {
                return error.IdentityElement;
            };

            return self;
        }

        pub fn computeSharedSecret(self: *Self, peer_public: []const u8) ![]const u8 {
            if (peer_public.len != 65 or peer_public[0] != 0x04) {
                return error.InvalidPublicKey;
            }

            self.shared_secret = Runtime.Crypto.P256.ecdh(self.secret_key, peer_public[0..65].*) catch {
                return error.IdentityElement;
            };

            return &self.shared_secret;
        }
    };
}

pub const HandshakeState = enum {
    initial,
    wait_server_hello,
    wait_encrypted_extensions,
    wait_certificate,
    wait_certificate_verify,
    wait_finished,
    connected,
    error_state,
    wait_server_key_exchange,
    wait_server_hello_done,
};

pub fn TranscriptHash(comptime Runtime: type) type {
    comptime {
        _ = runtime_suite.is(Runtime);
    }
    const Sha256 = Runtime.Crypto.Hash.Sha256();
    return struct {
        sha256: Sha256,

        const Self = @This();

        pub fn init() Self {
            return .{ .sha256 = Sha256.init() };
        }

        pub fn update(self: *Self, data: []const u8) void {
            self.sha256.update(data);
        }

        pub fn peek(self: *Self) [32]u8 {
            var copy = self.sha256;
            return copy.final();
        }

        pub fn final(self: *Self) [32]u8 {
            return self.sha256.final();
        }
    };
}

pub fn Tls12Prf(comptime Runtime: type) type {
    comptime {
        _ = runtime_suite.is(Runtime);
    }
    const HmacSha256 = Runtime.Crypto.Hmac.Sha256();
    return struct {
        pub fn prf(out: []u8, secret: []const u8, label: []const u8, seed: []const u8) void {
            var label_seed: [128]u8 = undefined;
            @memcpy(label_seed[0..label.len], label);
            @memcpy(label_seed[label.len..][0..seed.len], seed);
            const ls = label_seed[0 .. label.len + seed.len];

            var a: [32]u8 = undefined;
            HmacSha256.create(&a, ls, secret);

            var pos: usize = 0;
            while (pos < out.len) {
                var ctx = HmacSha256.init(secret);
                ctx.update(&a);
                ctx.update(ls);
                const p = ctx.final();

                const copy_len = @min(32, out.len - pos);
                @memcpy(out[pos..][0..copy_len], p[0..copy_len]);
                pos += copy_len;

                HmacSha256.create(&a, &a, secret);
            }
        }
    };
}

/// Client handshake state machine.
/// Generic over `Conn` (transport) and `Runtime` (sealed runtime suite).
pub fn ClientHandshake(comptime Conn: type, comptime Runtime: type) type {
    comptime {
        _ = runtime_suite.is(Runtime);
    }

    const HkdfSha256 = Runtime.Crypto.Hkdf.Sha256();
    const HmacSha256 = Runtime.Crypto.Hmac.Sha256();
    const Sha256 = Runtime.Crypto.Hash.Sha256();

    return struct {
        state: HandshakeState,
        version: ProtocolVersion,
        cipher_suite: CipherSuite,

        client_random: [32]u8,
        server_random: [32]u8,

        key_exchange: ?KeyExchange(Runtime),

        handshake_secret: [48]u8,
        master_secret: [48]u8,
        client_handshake_traffic_secret: [48]u8,
        server_handshake_traffic_secret: [48]u8,
        client_application_traffic_secret: [48]u8,
        server_application_traffic_secret: [48]u8,

        tls12_server_pubkey: [97]u8,
        tls12_server_pubkey_len: u8,
        tls12_named_group: NamedGroup,

        server_cert_der: [4096]u8,
        server_cert_der_len: u16,

        transcript_hash: TranscriptHash(Runtime),

        records: record.RecordLayer(Conn, Runtime),

        hostname: []const u8,
        allocator: std.mem.Allocator,
        skip_verify: bool,

        rng: Runtime.Rng,

        const Self = @This();

        pub fn init(
            conn: *Conn,
            hostname: []const u8,
            allocator: std.mem.Allocator,
            skip_verify: bool,
            rng: Runtime.Rng,
        ) !Self {
            var self = Self{
                .state = .initial,
                .version = .tls_1_3,
                .cipher_suite = .TLS_AES_128_GCM_SHA256,
                .client_random = [_]u8{0} ** 32,
                .server_random = [_]u8{0} ** 32,
                .key_exchange = null,
                .handshake_secret = [_]u8{0} ** 48,
                .master_secret = [_]u8{0} ** 48,
                .client_handshake_traffic_secret = [_]u8{0} ** 48,
                .server_handshake_traffic_secret = [_]u8{0} ** 48,
                .client_application_traffic_secret = [_]u8{0} ** 48,
                .server_application_traffic_secret = [_]u8{0} ** 48,
                .tls12_server_pubkey = [_]u8{0} ** 97,
                .tls12_server_pubkey_len = 0,
                .tls12_named_group = .x25519,
                .server_cert_der = [_]u8{0} ** 4096,
                .server_cert_der_len = 0,
                .transcript_hash = TranscriptHash(Runtime).init(),
                .records = record.RecordLayer(Conn, Runtime).init(conn),
                .hostname = hostname,
                .allocator = allocator,
                .skip_verify = skip_verify,
                .rng = rng,
            };

            try self.rng.fill(&self.client_random);

            return self;
        }

        pub fn handshake(self: *Self, buffer: []u8) !void {
            try self.sendClientHello(buffer);
            self.state = .wait_server_hello;

            while (self.state != .connected and self.state != .error_state) {
                try self.processServerMessage(buffer);
            }

            if (self.state == .error_state) {
                return error.HandshakeFailed;
            }
        }

        fn sendClientHello(self: *Self, buffer: []u8) !void {
            var msg_buf: [512]u8 = undefined;
            var pos: usize = 0;

            std.mem.writeInt(u16, msg_buf[pos..][0..2], @intFromEnum(ProtocolVersion.tls_1_2), .big);
            pos += 2;

            @memcpy(msg_buf[pos..][0..32], &self.client_random);
            pos += 32;

            msg_buf[pos] = 0;
            pos += 1;

            const cipher_suites = [_]CipherSuite{
                .TLS_AES_128_GCM_SHA256,
                .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
            };
            std.mem.writeInt(u16, msg_buf[pos..][0..2], @intCast(cipher_suites.len * 2), .big);
            pos += 2;
            for (cipher_suites) |suite| {
                std.mem.writeInt(u16, msg_buf[pos..][0..2], @intFromEnum(suite), .big);
                pos += 2;
            }

            msg_buf[pos] = 1;
            pos += 1;
            msg_buf[pos] = 0;
            pos += 1;

            var ext_buf: [512]u8 = undefined;
            var ext_builder = extensions.ExtensionBuilder.init(&ext_buf);

            try ext_builder.addServerName(self.hostname);
            try ext_builder.addEcPointFormats();

            const versions = [_]ProtocolVersion{ .tls_1_3, .tls_1_2 };
            try ext_builder.addSupportedVersions(&versions);

            const groups = [_]NamedGroup{ .x25519, .secp256r1 };
            try ext_builder.addSupportedGroups(&groups);

            const sig_algs = [_]SignatureScheme{
                .ecdsa_secp256r1_sha256,
                .ecdsa_secp384r1_sha384,
                .rsa_pss_rsae_sha256,
                .rsa_pss_rsae_sha384,
                .rsa_pkcs1_sha256,
                .rsa_pkcs1_sha384,
            };
            try ext_builder.addSignatureAlgorithms(&sig_algs);

            self.key_exchange = try KeyExchange(Runtime).generate(.x25519, self.rng);
            const key_share_entries = [_]extensions.KeyShareEntry{
                .{ .group = .x25519, .key_exchange = self.key_exchange.?.publicKey() },
            };
            try ext_builder.addKeyShareClient(&key_share_entries);

            const psk_modes = [_]common.PskKeyExchangeMode{.psk_dhe_ke};
            try ext_builder.addPskKeyExchangeModes(&psk_modes);

            const ext_data = ext_builder.getData();
            std.mem.writeInt(u16, msg_buf[pos..][0..2], @intCast(ext_data.len), .big);
            pos += 2;
            @memcpy(msg_buf[pos..][0..ext_data.len], ext_data);
            pos += ext_data.len;

            var handshake_buf: [1024]u8 = undefined;
            const header = HandshakeHeader{
                .msg_type = .client_hello,
                .length = @intCast(pos),
            };
            try header.serialize(handshake_buf[0..4]);
            @memcpy(handshake_buf[4..][0..pos], msg_buf[0..pos]);

            self.transcript_hash.update(handshake_buf[0 .. 4 + pos]);

            _ = try self.records.writeRecord(.handshake, handshake_buf[0 .. 4 + pos], buffer);
        }

        fn processServerMessage(self: *Self, buffer: []u8) !void {
            var plaintext: [common.MAX_CIPHERTEXT_LEN]u8 = undefined;
            const result = try self.records.readRecord(buffer, &plaintext);

            switch (result.content_type) {
                .handshake => try self.processHandshake(plaintext[0..result.length]),
                .alert => {
                    self.state = .error_state;
                    return error.AlertReceived;
                },
                .change_cipher_spec => {},
                else => {
                    self.state = .error_state;
                    return error.UnexpectedMessage;
                },
            }
        }

        fn processHandshake(self: *Self, data: []const u8) !void {
            var pos: usize = 0;
            while (pos + 4 <= data.len) {
                const header = try HandshakeHeader.parse(data[pos..]);

                const total_len = 4 + @as(usize, header.length);
                if (pos + total_len > data.len) return error.InvalidHandshake;

                const msg_data = data[pos + 4 ..][0..header.length];
                const raw_msg = data[pos..][0..total_len];

                const needs_pre_verify = (header.msg_type == .finished) or
                    (header.msg_type == .certificate_verify);

                if (needs_pre_verify) {
                    switch (header.msg_type) {
                        .certificate_verify => {
                            try self.processCertificateVerify(msg_data);
                            self.transcript_hash.update(raw_msg);
                        },
                        .finished => {
                            try self.processFinished(msg_data, raw_msg);
                        },
                        else => unreachable,
                    }
                } else {
                    self.transcript_hash.update(raw_msg);

                    switch (header.msg_type) {
                        .server_hello => try self.processServerHello(msg_data),
                        .encrypted_extensions => try self.processEncryptedExtensions(msg_data),
                        .certificate => try self.processCertificate(msg_data),
                        .server_key_exchange => try self.processServerKeyExchange(msg_data),
                        .server_hello_done => try self.processServerHelloDone(msg_data),
                        .finished => try self.processFinished(msg_data, raw_msg),
                        else => {},
                    }
                }

                pos += total_len;
            }
        }

        fn processServerHello(self: *Self, data: []const u8) !void {
            if (self.state != .wait_server_hello) return error.UnexpectedMessage;
            if (data.len < 34) return error.InvalidHandshake;

            const legacy_version_raw = std.mem.readInt(u16, data[0..2], .big);
            const legacy_version: ProtocolVersion = std.meta.intToEnum(ProtocolVersion, legacy_version_raw) catch {
                return error.UnsupportedVersion;
            };

            @memcpy(&self.server_random, data[2..34]);

            const hello_retry_magic = [_]u8{
                0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11,
                0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91,
                0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E,
                0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C,
            };
            if (std.mem.eql(u8, &self.server_random, &hello_retry_magic)) {
                return error.HelloRetryNotSupported;
            }

            var pos: usize = 34;

            if (pos >= data.len) return error.InvalidHandshake;
            const session_id_len = data[pos];
            pos += 1;
            if (pos + session_id_len > data.len) return error.InvalidHandshake;
            pos += session_id_len;

            if (pos + 2 > data.len) return error.InvalidHandshake;
            const cipher_raw = std.mem.readInt(u16, data[pos..][0..2], .big);
            self.cipher_suite = std.meta.intToEnum(CipherSuite, cipher_raw) catch {
                return error.UnsupportedCipherSuite;
            };
            pos += 2;

            pos += 1;

            self.version = legacy_version;

            if (pos + 2 <= data.len) {
                const ext_len = std.mem.readInt(u16, data[pos..][0..2], .big);
                pos += 2;

                if (pos + ext_len <= data.len) {
                    const ext_data = data[pos..][0..ext_len];
                    var ext_pos: usize = 0;

                    while (ext_pos + 4 <= ext_data.len) {
                        const ext_type_raw = std.mem.readInt(u16, ext_data[ext_pos..][0..2], .big);
                        ext_pos += 2;
                        const ext_size = std.mem.readInt(u16, ext_data[ext_pos..][0..2], .big);
                        ext_pos += 2;

                        if (ext_pos + ext_size > ext_data.len) break;

                        const ext_content = ext_data[ext_pos..][0..ext_size];
                        ext_pos += ext_size;

                        const ext_type = std.meta.intToEnum(common.ExtensionType, ext_type_raw) catch continue;

                        switch (ext_type) {
                            .supported_versions => {
                                self.version = try extensions.parseSupportedVersion(ext_content);
                            },
                            .key_share => {
                                const key_share = try extensions.parseKeyShareServer(ext_content);
                                if (self.key_exchange) |*kx| {
                                    const shared = try kx.computeSharedSecret(key_share.key_exchange);
                                    try self.deriveHandshakeKeys(shared);
                                }
                            },
                            else => {},
                        }
                    }
                }
            }

            if (self.version == .tls_1_3) {
                self.state = .wait_encrypted_extensions;
            } else {
                self.state = .wait_certificate;
            }
        }

        fn processEncryptedExtensions(self: *Self, data: []const u8) !void {
            if (self.state != .wait_encrypted_extensions) return error.UnexpectedMessage;
            _ = data;
            self.state = .wait_certificate;
        }

        fn processCertificate(self: *Self, data: []const u8) !void {
            if (self.state != .wait_certificate) return error.UnexpectedMessage;

            var pos: usize = 0;
            if (self.version == .tls_1_3) {
                if (data.len < 1) return error.InvalidHandshake;
                const context_len = data[0];
                pos = 1 + context_len;
            }

            if (pos + 3 > data.len) return error.InvalidHandshake;
            const certs_len = std.mem.readInt(u24, data[pos..][0..3], .big);
            pos += 3;

            const cert_list_end = pos + certs_len;
            if (cert_list_end > data.len) return error.InvalidHandshake;

            var cert_chain: [10][]const u8 = undefined;
            var cert_count: usize = 0;

            while (pos < cert_list_end and cert_count < 10) {
                if (pos + 3 > cert_list_end) return error.InvalidHandshake;
                const cert_len = std.mem.readInt(u24, data[pos..][0..3], .big);
                pos += 3;

                if (pos + cert_len > cert_list_end) return error.InvalidHandshake;
                cert_chain[cert_count] = data[pos..][0..cert_len];
                cert_count += 1;
                pos += cert_len;

                if (self.version == .tls_1_3) {
                    if (pos + 2 > cert_list_end) return error.InvalidHandshake;
                    const ext_len = std.mem.readInt(u16, data[pos..][0..2], .big);
                    pos += 2 + ext_len;
                }
            }

            if (cert_count == 0) return error.InvalidHandshake;

            const leaf_cert = cert_chain[0];
            if (leaf_cert.len > self.server_cert_der.len) {
                return error.CertificateTooLarge;
            }
            @memcpy(self.server_cert_der[0..leaf_cert.len], leaf_cert);
            self.server_cert_der_len = @intCast(leaf_cert.len);

            if (!self.skip_verify) {
                const builtin = @import("builtin");
                const now_sec: i64 = if (builtin.os.tag == .freestanding)
                    0
                else
                    std.time.timestamp();

                var store = Runtime.Crypto.X509.init(self.allocator) catch {
                    return error.CertificateVerificationFailed;
                };
                defer store.deinit();

                store.verifyChain(
                    cert_chain[0..cert_count],
                    if (self.hostname.len > 0) self.hostname else null,
                    now_sec,
                ) catch {
                    return error.CertificateVerificationFailed;
                };
            }

            if (self.version == .tls_1_3) {
                self.state = .wait_certificate_verify;
            } else {
                self.state = .wait_server_key_exchange;
            }
        }

        fn processServerKeyExchange(self: *Self, data: []const u8) !void {
            if (self.version == .tls_1_3) return error.UnexpectedMessage;
            if (self.state != .wait_server_key_exchange) return error.UnexpectedMessage;

            if (data.len < 4) return error.InvalidHandshake;

            const curve_type = data[0];
            if (curve_type != 0x03) return error.UnsupportedGroup;

            const group_raw = std.mem.readInt(u16, data[1..3], .big);
            const named_group: NamedGroup = std.meta.intToEnum(NamedGroup, group_raw) catch {
                return error.UnsupportedGroup;
            };
            const pubkey_len = data[3];

            if (data.len < 4 + pubkey_len) return error.InvalidHandshake;
            const server_pubkey = data[4..][0..pubkey_len];

            const sig_offset = 4 + pubkey_len;
            if (data.len < sig_offset + 4) return error.InvalidHandshake;

            const sig_scheme = std.mem.readInt(u16, data[sig_offset..][0..2], .big);
            const sig_len = std.mem.readInt(u16, data[sig_offset + 2 ..][0..2], .big);

            if (data.len < sig_offset + 4 + sig_len) return error.InvalidHandshake;
            const signature = data[sig_offset + 4 ..][0..sig_len];

            const params_len = 4 + pubkey_len;
            var signed_data: [32 + 32 + 4 + 256]u8 = undefined;
            const total_len = 32 + 32 + params_len;
            @memcpy(signed_data[0..32], &self.client_random);
            @memcpy(signed_data[32..64], &self.server_random);
            @memcpy(signed_data[64..][0..params_len], data[0..params_len]);

            const cert_der = self.server_cert_der[0..self.server_cert_der_len];
            const Certificate = std.crypto.Certificate;
            const cert = Certificate{ .buffer = cert_der, .index = 0 };
            const parsed = cert.parse() catch return error.InvalidCertificate;

            try verifySignature(sig_scheme, signed_data[0..total_len], signature, parsed);

            self.key_exchange = try KeyExchange(Runtime).generate(named_group, self.rng);

            if (pubkey_len > self.tls12_server_pubkey.len) return error.InvalidPublicKey;

            @memcpy(self.tls12_server_pubkey[0..pubkey_len], server_pubkey);
            self.tls12_server_pubkey_len = pubkey_len;
            self.tls12_named_group = named_group;

            self.state = .wait_server_hello_done;
        }

        fn processServerHelloDone(self: *Self, data: []const u8) !void {
            if (self.version == .tls_1_3) return error.UnexpectedMessage;
            if (self.state != .wait_server_hello_done) return error.UnexpectedMessage;
            _ = data;

            try self.sendClientKeyExchange();

            self.state = .wait_finished;
        }

        fn sendClientKeyExchange(self: *Self) !void {
            if (self.key_exchange == null) return error.InvalidHandshake;

            var msg_buf: [256]u8 = undefined;
            var pos: usize = 0;

            const pubkey = self.key_exchange.?.publicKey();
            msg_buf[pos] = @intCast(pubkey.len);
            pos += 1;
            @memcpy(msg_buf[pos..][0..pubkey.len], pubkey);
            pos += pubkey.len;

            var handshake_buf: [512]u8 = undefined;
            const header = HandshakeHeader{
                .msg_type = .client_key_exchange,
                .length = @intCast(pos),
            };
            try header.serialize(handshake_buf[0..4]);
            @memcpy(handshake_buf[4..][0..pos], msg_buf[0..pos]);

            self.transcript_hash.update(handshake_buf[0 .. 4 + pos]);

            var write_buf: [1024]u8 = undefined;
            _ = try self.records.writeRecord(.handshake, handshake_buf[0 .. 4 + pos], &write_buf);

            const server_pubkey_slice = self.tls12_server_pubkey[0..self.tls12_server_pubkey_len];
            const shared_secret = try self.key_exchange.?.computeSharedSecret(server_pubkey_slice);

            try self.deriveTls12Keys(shared_secret);

            try self.sendChangeCipherSpec();

            try self.sendFinished();
        }

        fn sendChangeCipherSpec(self: *Self) !void {
            var write_buf: [64]u8 = undefined;

            const header = record.RecordHeader{
                .content_type = .change_cipher_spec,
                .legacy_version = .tls_1_2,
                .length = 1,
            };
            try header.serialize(write_buf[0..5]);
            write_buf[5] = 1;

            var written: usize = 0;
            while (written < 6) {
                const n = self.records.conn.write(write_buf[written..6]) catch return error.UnexpectedRecord;
                if (n == 0) return error.UnexpectedRecord;
                written += n;
            }
        }

        fn sendFinished(self: *Self) !void {
            const verify_data = self.computeVerifyData(true);

            var handshake_buf: [64]u8 = undefined;
            const header = HandshakeHeader{
                .msg_type = .finished,
                .length = 12,
            };
            try header.serialize(handshake_buf[0..4]);
            @memcpy(handshake_buf[4..16], verify_data[0..12]);

            self.transcript_hash.update(handshake_buf[0..16]);

            var write_buf: [128]u8 = undefined;
            _ = try self.records.writeRecord(.handshake, handshake_buf[0..16], &write_buf);
        }

        fn deriveTls12Keys(self: *Self, pre_master_secret: []const u8) !void {
            const Prf = Tls12Prf(Runtime);

            var seed: [64]u8 = undefined;
            @memcpy(seed[0..32], &self.client_random);
            @memcpy(seed[32..64], &self.server_random);

            var master_secret: [48]u8 = undefined;
            Prf.prf(&master_secret, pre_master_secret, "master secret", &seed);
            @memcpy(self.master_secret[0..48], &master_secret);

            @memcpy(seed[0..32], &self.server_random);
            @memcpy(seed[32..64], &self.client_random);

            var key_block: [72]u8 = undefined;
            Prf.prf(&key_block, &master_secret, "key expansion", &seed);

            const key_len = self.cipher_suite.keyLength();
            const iv_len: usize = 4;

            const client_write_key = key_block[0..key_len];
            const server_write_key = key_block[key_len..][0..key_len];
            const client_write_iv = key_block[2 * key_len ..][0..iv_len];
            const server_write_iv = key_block[2 * key_len + iv_len ..][0..iv_len];

            var client_iv: [12]u8 = undefined;
            var server_iv: [12]u8 = undefined;
            @memcpy(client_iv[0..iv_len], client_write_iv);
            @memset(client_iv[iv_len..], 0);
            @memcpy(server_iv[0..iv_len], server_write_iv);
            @memset(server_iv[iv_len..], 0);

            const write_cipher = try record.CipherState(Runtime).init(self.cipher_suite, client_write_key, &client_iv);
            const read_cipher = try record.CipherState(Runtime).init(self.cipher_suite, server_write_key, &server_iv);

            self.records.setWriteCipher(write_cipher);
            self.records.setReadCipher(read_cipher);

            self.records.version = .tls_1_2;
        }

        fn computeVerifyData(self: *Self, is_client: bool) [12]u8 {
            const Prf = Tls12Prf(Runtime);
            const label = if (is_client) "client finished" else "server finished";

            const transcript = self.transcript_hash.peek();
            var verify_data: [12]u8 = undefined;
            Prf.prf(&verify_data, self.master_secret[0..48], label, &transcript);
            return verify_data;
        }

        fn processCertificateVerify(self: *Self, data: []const u8) !void {
            if (self.state != .wait_certificate_verify) return error.UnexpectedMessage;

            if (data.len < 4) return error.InvalidHandshake;

            const sig_scheme = std.mem.readInt(u16, data[0..2], .big);
            const sig_len = std.mem.readInt(u16, data[2..4], .big);

            if (data.len < 4 + sig_len) return error.InvalidHandshake;
            const signature = data[4..][0..sig_len];

            const context_string = "TLS 1.3, server CertificateVerify";
            const transcript = self.transcript_hash.peek();

            var content: [64 + context_string.len + 1 + 32]u8 = undefined;
            @memset(content[0..64], 0x20);
            @memcpy(content[64..][0..context_string.len], context_string);
            content[64 + context_string.len] = 0x00;
            @memcpy(content[64 + context_string.len + 1 ..][0..32], &transcript);

            const cert_der = self.server_cert_der[0..self.server_cert_der_len];
            const Certificate = std.crypto.Certificate;
            const cert = Certificate{ .buffer = cert_der, .index = 0 };
            const parsed = cert.parse() catch return error.InvalidCertificate;

            try verifySignature(sig_scheme, &content, signature, parsed);

            self.state = .wait_finished;
        }

        fn verifySignature(
            sig_scheme: u16,
            content: []const u8,
            signature: []const u8,
            parsed_cert: std.crypto.Certificate.Parsed,
        ) !void {
            switch (sig_scheme) {
                0x0403 => {
                    if (!Runtime.Crypto.Pki.verifyEcdsaP256(signature, content, parsed_cert.pubKey()))
                        return error.SignatureVerificationFailed;
                },
                0x0503 => {
                    if (!Runtime.Crypto.Pki.verifyEcdsaP384(signature, content, parsed_cert.pubKey()))
                        return error.SignatureVerificationFailed;
                },
                0x0401 => {
                    Runtime.Crypto.Rsa.verifyPKCS1v1_5(signature, content, parsed_cert.pubKey(), .sha256) catch
                        return error.SignatureVerificationFailed;
                },
                0x0501 => {
                    Runtime.Crypto.Rsa.verifyPKCS1v1_5(signature, content, parsed_cert.pubKey(), .sha384) catch
                        return error.SignatureVerificationFailed;
                },
                0x0804 => {
                    Runtime.Crypto.Rsa.verifyPSS(signature, content, parsed_cert.pubKey(), .sha256) catch
                        return error.SignatureVerificationFailed;
                },
                0x0805 => {
                    Runtime.Crypto.Rsa.verifyPSS(signature, content, parsed_cert.pubKey(), .sha384) catch
                        return error.SignatureVerificationFailed;
                },
                else => {
                    return error.UnsupportedSignatureAlgorithm;
                },
            }
        }

        fn processFinished(self: *Self, data: []const u8, raw_msg: []const u8) !void {
            if (self.state != .wait_finished) return error.UnexpectedMessage;

            if (self.version == .tls_1_3) {
                const hash_len = 32;

                if (data.len < hash_len) return error.InvalidHandshake;

                const finished_key = kdf.hkdfExpandLabel(
                    HkdfSha256,
                    self.server_handshake_traffic_secret[0..hash_len].*,
                    "finished",
                    "",
                    hash_len,
                );

                const transcript = self.transcript_hash.peek();
                var expected: [32]u8 = undefined;
                HmacSha256.create(&expected, &transcript, &finished_key);

                if (!std.mem.eql(u8, data[0..hash_len], &expected)) {
                    return error.BadRecordMac;
                }

                self.transcript_hash.update(raw_msg);

                try self.deriveApplicationKeys();

                try self.sendTls13Finished();
            } else {
                if (data.len < 12) return error.InvalidHandshake;

                const expected = self.computeVerifyData(false);

                if (!std.mem.eql(u8, data[0..12], &expected)) {
                    return error.BadRecordMac;
                }

                self.transcript_hash.update(raw_msg);
            }

            self.state = .connected;
        }

        fn sendTls13Finished(self: *Self) !void {
            const hash_len = 32;

            const finished_key = kdf.hkdfExpandLabel(
                HkdfSha256,
                self.client_handshake_traffic_secret[0..hash_len].*,
                "finished",
                "",
                hash_len,
            );

            const transcript = self.transcript_hash.peek();
            var verify_data: [32]u8 = undefined;
            HmacSha256.create(&verify_data, &transcript, &finished_key);

            var handshake_buf: [64]u8 = undefined;
            const header = HandshakeHeader{
                .msg_type = .finished,
                .length = 32,
            };
            try header.serialize(handshake_buf[0..4]);
            @memcpy(handshake_buf[4..36], &verify_data);

            self.transcript_hash.update(handshake_buf[0..36]);

            const key_len = self.cipher_suite.keyLength();
            var client_key_buf: [32]u8 = undefined;
            if (key_len == 16) {
                const ck16 = kdf.hkdfExpandLabel(HkdfSha256, self.client_handshake_traffic_secret[0..hash_len].*, "key", "", 16);
                @memcpy(client_key_buf[0..16], &ck16);
            } else {
                const ck32 = kdf.hkdfExpandLabel(HkdfSha256, self.client_handshake_traffic_secret[0..hash_len].*, "key", "", 32);
                @memcpy(&client_key_buf, &ck32);
            }
            const client_iv = kdf.hkdfExpandLabel(
                HkdfSha256,
                self.client_handshake_traffic_secret[0..hash_len].*,
                "iv",
                "",
                12,
            );

            const write_cipher = try record.CipherState(Runtime).init(self.cipher_suite, client_key_buf[0..key_len], &client_iv);
            self.records.setWriteCipher(write_cipher);

            var write_buf: [128]u8 = undefined;
            _ = try self.records.writeRecord(.handshake, handshake_buf[0..36], &write_buf);

            var app_client_key_buf: [32]u8 = undefined;
            if (key_len == 16) {
                const ck16 = kdf.hkdfExpandLabel(HkdfSha256, self.client_application_traffic_secret[0..hash_len].*, "key", "", 16);
                @memcpy(app_client_key_buf[0..16], &ck16);
            } else {
                const ck32 = kdf.hkdfExpandLabel(HkdfSha256, self.client_application_traffic_secret[0..hash_len].*, "key", "", 32);
                @memcpy(&app_client_key_buf, &ck32);
            }
            const app_client_iv = kdf.hkdfExpandLabel(
                HkdfSha256,
                self.client_application_traffic_secret[0..hash_len].*,
                "iv",
                "",
                12,
            );
            const app_write_cipher = try record.CipherState(Runtime).init(self.cipher_suite, app_client_key_buf[0..key_len], &app_client_iv);
            self.records.setWriteCipher(app_write_cipher);
        }

        fn deriveHandshakeKeys(self: *Self, shared_secret: []const u8) !void {
            const hash_len = 32;

            const zeros: [hash_len]u8 = [_]u8{0} ** hash_len;
            const early_secret = HkdfSha256.extract(&zeros, &zeros);

            const empty_hash = emptyHash();
            const derived_secret = kdf.hkdfExpandLabel(
                HkdfSha256,
                early_secret,
                "derived",
                &empty_hash,
                hash_len,
            );

            var hs_secret: [hash_len]u8 = undefined;
            if (shared_secret.len <= hash_len) {
                @memcpy(hs_secret[0..shared_secret.len], shared_secret);
                @memset(hs_secret[shared_secret.len..], 0);
            } else {
                @memcpy(&hs_secret, shared_secret[0..hash_len]);
            }
            self.handshake_secret = undefined;
            @memcpy(self.handshake_secret[0..hash_len], &HkdfSha256.extract(&derived_secret, &hs_secret));

            const transcript = self.transcript_hash.peek();
            self.client_handshake_traffic_secret = undefined;
            @memcpy(
                self.client_handshake_traffic_secret[0..hash_len],
                &kdf.hkdfExpandLabel(HkdfSha256, self.handshake_secret[0..hash_len].*, "c hs traffic", &transcript, hash_len),
            );
            self.server_handshake_traffic_secret = undefined;
            @memcpy(
                self.server_handshake_traffic_secret[0..hash_len],
                &kdf.hkdfExpandLabel(HkdfSha256, self.handshake_secret[0..hash_len].*, "s hs traffic", &transcript, hash_len),
            );

            const key_len = self.cipher_suite.keyLength();
            var server_key_buf: [32]u8 = undefined;
            if (key_len == 16) {
                const key16 = kdf.hkdfExpandLabel(HkdfSha256, self.server_handshake_traffic_secret[0..hash_len].*, "key", "", 16);
                @memcpy(server_key_buf[0..16], &key16);
            } else {
                const key32 = kdf.hkdfExpandLabel(HkdfSha256, self.server_handshake_traffic_secret[0..hash_len].*, "key", "", 32);
                @memcpy(&server_key_buf, &key32);
            }
            const server_iv = kdf.hkdfExpandLabel(
                HkdfSha256,
                self.server_handshake_traffic_secret[0..hash_len].*,
                "iv",
                "",
                12,
            );

            const cipher = try record.CipherState(Runtime).init(self.cipher_suite, server_key_buf[0..key_len], &server_iv);
            self.records.setReadCipher(cipher);

            self.records.version = .tls_1_3;
        }

        fn deriveApplicationKeys(self: *Self) !void {
            const hash_len = 32;

            const empty_hash = emptyHash();
            const derived = kdf.hkdfExpandLabel(
                HkdfSha256,
                self.handshake_secret[0..hash_len].*,
                "derived",
                &empty_hash,
                hash_len,
            );
            const zeros: [hash_len]u8 = [_]u8{0} ** hash_len;
            self.master_secret = undefined;
            @memcpy(self.master_secret[0..hash_len], &HkdfSha256.extract(&derived, &zeros));

            const transcript = self.transcript_hash.peek();
            self.client_application_traffic_secret = undefined;
            @memcpy(
                self.client_application_traffic_secret[0..hash_len],
                &kdf.hkdfExpandLabel(HkdfSha256, self.master_secret[0..hash_len].*, "c ap traffic", &transcript, hash_len),
            );
            self.server_application_traffic_secret = undefined;
            @memcpy(
                self.server_application_traffic_secret[0..hash_len],
                &kdf.hkdfExpandLabel(HkdfSha256, self.master_secret[0..hash_len].*, "s ap traffic", &transcript, hash_len),
            );

            const key_len = self.cipher_suite.keyLength();
            var client_key_buf: [32]u8 = undefined;
            var server_key_buf: [32]u8 = undefined;
            if (key_len == 16) {
                const ck16 = kdf.hkdfExpandLabel(HkdfSha256, self.client_application_traffic_secret[0..hash_len].*, "key", "", 16);
                const sk16 = kdf.hkdfExpandLabel(HkdfSha256, self.server_application_traffic_secret[0..hash_len].*, "key", "", 16);
                @memcpy(client_key_buf[0..16], &ck16);
                @memcpy(server_key_buf[0..16], &sk16);
            } else {
                const ck32 = kdf.hkdfExpandLabel(HkdfSha256, self.client_application_traffic_secret[0..hash_len].*, "key", "", 32);
                const sk32 = kdf.hkdfExpandLabel(HkdfSha256, self.server_application_traffic_secret[0..hash_len].*, "key", "", 32);
                @memcpy(&client_key_buf, &ck32);
                @memcpy(&server_key_buf, &sk32);
            }
            const client_iv = kdf.hkdfExpandLabel(
                HkdfSha256,
                self.client_application_traffic_secret[0..hash_len].*,
                "iv",
                "",
                12,
            );
            const server_iv = kdf.hkdfExpandLabel(
                HkdfSha256,
                self.server_application_traffic_secret[0..hash_len].*,
                "iv",
                "",
                12,
            );

            const write_cipher = try record.CipherState(Runtime).init(self.cipher_suite, client_key_buf[0..key_len], &client_iv);
            const read_cipher = try record.CipherState(Runtime).init(self.cipher_suite, server_key_buf[0..key_len], &server_iv);

            self.records.setWriteCipher(write_cipher);
            self.records.setReadCipher(read_cipher);
        }

        fn emptyHash() [32]u8 {
            var hash: [32]u8 = undefined;
            Sha256.hash("", &hash);
            return hash;
        }
    };
}

pub const HandshakeError = error{
    BufferTooSmall,
    InvalidHandshake,
    UnexpectedMessage,
    AlertReceived,
    HandshakeFailed,
    UnsupportedGroup,
    InvalidPublicKey,
    HelloRetryNotSupported,
    UnsupportedCipherSuite,
    InvalidKeyLength,
    InvalidIvLength,
    RecordTooLarge,
    DecryptionFailed,
    BadRecordMac,
    UnexpectedRecord,
    IdentityElement,
    CertificateVerificationFailed,
};
