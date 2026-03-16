const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const module = embed.pkg.net.tls.handshake;
const HandshakeHeader = module.HandshakeHeader;
const KeyExchange = module.KeyExchange;
const HandshakeState = module.HandshakeState;
const ClientHandshake = module.ClientHandshake;
const HandshakeError = module.HandshakeError;
const runtime = module.runtime;
const common = module.common;
const extensions = module.extensions;
const record = module.record;
const kdf = module.kdf;
const HandshakeType = module.HandshakeType;
const ProtocolVersion = module.ProtocolVersion;
const CipherSuite = module.CipherSuite;
const NamedGroup = module.NamedGroup;
const SignatureScheme = module.SignatureScheme;
const ContentType = module.ContentType;

fn testRngFill(buf: []u8) void {
    std.crypto.random.bytes(buf);
}
const X25519KeyExchange = module.X25519KeyExchange;
const P256KeyExchange = module.P256KeyExchange;
const TranscriptHash = module.TranscriptHash;
const Tls12Prf = module.Tls12Prf;

test "HandshakeHeader parse and serialize" {
    const header = HandshakeHeader{
        .msg_type = .client_hello,
        .length = 256,
    };

    var buf: [4]u8 = undefined;
    try header.serialize(&buf);

    const parsed = try HandshakeHeader.parse(&buf);
    try std.testing.expectEqual(header.msg_type, parsed.msg_type);
    try std.testing.expectEqual(header.length, parsed.length);
}

test "TranscriptHash" {
    const Crypto = runtime.std.Crypto;

    var hash = TranscriptHash(Crypto).init();
    hash.update("hello");
    hash.update("world");

    const result1 = hash.peek();
    const result2 = hash.peek();

    try std.testing.expectEqual(result1, result2);
}

test "TLS 1.2 PRF basic" {
    const Crypto = runtime.std.Crypto;

    const secret = "secret";
    const label = "test label";
    const seed = "seed";

    var out: [32]u8 = undefined;
    Tls12Prf(Crypto).prf(&out, secret, label, seed);

    var out2: [32]u8 = undefined;
    Tls12Prf(Crypto).prf(&out2, secret, label, seed);
    try std.testing.expectEqualSlices(u8, &out, &out2);

    var out3: [32]u8 = undefined;
    Tls12Prf(Crypto).prf(&out3, "different", label, seed);
    try std.testing.expect(!std.mem.eql(u8, &out, &out3));
}

test "TLS 1.2 PRF output length" {
    const Crypto = runtime.std.Crypto;

    const secret = "secret";
    const label = "label";
    const seed = "seed";

    var out12: [12]u8 = undefined;
    Tls12Prf(Crypto).prf(&out12, secret, label, seed);

    var out48: [48]u8 = undefined;
    Tls12Prf(Crypto).prf(&out48, secret, label, seed);

    try std.testing.expectEqualSlices(u8, &out12, out48[0..12]);
}

test "ClientHandshake init with Conn" {
    const Crypto = runtime.std.Crypto;
    const conn_mod = embed.pkg.net.conn;

    const MockConn = struct {
        const Self = @This();
        pub fn read(_: *Self, _: []u8) conn_mod.Error!usize {
            return 0;
        }
        pub fn write(_: *Self, _: []const u8) conn_mod.Error!usize {
            return 0;
        }
        pub fn close(_: *Self) void {}
    };

    var conn = MockConn{};
    const Hs = ClientHandshake(MockConn, Crypto);

    const hs = Hs.init(&conn, "example.com", std.testing.allocator, null, &testRngFill);

    try std.testing.expectEqualStrings("example.com", hs.hostname);
    try std.testing.expect(hs.state == .initial);
}

test "HandshakeHeader parse too small buffer" {
    const buf: [3]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, HandshakeHeader.parse(&buf));
}

test "HandshakeHeader serialize too small buffer" {
    const header = HandshakeHeader{ .msg_type = .client_hello, .length = 0 };
    var buf: [3]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, header.serialize(&buf));
}

test "HandshakeHeader all message types roundtrip" {
    const types_to_test = [_]HandshakeType{
        .client_hello,
        .server_hello,
        .encrypted_extensions,
        .certificate,
        .certificate_verify,
        .finished,
        .server_key_exchange,
        .server_hello_done,
        .client_key_exchange,
    };
    for (types_to_test) |mt| {
        const header = HandshakeHeader{ .msg_type = mt, .length = 12345 };
        var buf: [4]u8 = undefined;
        try header.serialize(&buf);
        const parsed = try HandshakeHeader.parse(&buf);
        try std.testing.expectEqual(mt, parsed.msg_type);
        try std.testing.expectEqual(@as(u24, 12345), parsed.length);
    }
}

test "HandshakeHeader max length" {
    const header = HandshakeHeader{ .msg_type = .client_hello, .length = std.math.maxInt(u24) };
    var buf: [4]u8 = undefined;
    try header.serialize(&buf);
    const parsed = try HandshakeHeader.parse(&buf);
    try std.testing.expectEqual(std.math.maxInt(u24), parsed.length);
}

test "TranscriptHash final differs from peek after more updates" {
    const Crypto = runtime.std.Crypto;

    var hash = TranscriptHash(Crypto).init();
    hash.update("part1");
    const peeked = hash.peek();

    hash.update("part2");
    const peeked2 = hash.peek();

    try std.testing.expect(!std.mem.eql(u8, &peeked, &peeked2));
}

test "TranscriptHash empty input" {
    const Crypto = runtime.std.Crypto;

    var hash = TranscriptHash(Crypto).init();
    const result = hash.peek();

    var expected: [32]u8 = undefined;
    Crypto.Sha256.hash("", &expected);
    try std.testing.expectEqualSlices(u8, &expected, &result);
}

test "TLS 1.2 PRF different labels produce different output" {
    const Crypto = runtime.std.Crypto;

    var out1: [32]u8 = undefined;
    Tls12Prf(Crypto).prf(&out1, "secret", "label A", "seed");

    var out2: [32]u8 = undefined;
    Tls12Prf(Crypto).prf(&out2, "secret", "label B", "seed");

    try std.testing.expect(!std.mem.eql(u8, &out1, &out2));
}

test "TLS 1.2 PRF different seeds produce different output" {
    const Crypto = runtime.std.Crypto;

    var out1: [32]u8 = undefined;
    Tls12Prf(Crypto).prf(&out1, "secret", "label", "seed A");

    var out2: [32]u8 = undefined;
    Tls12Prf(Crypto).prf(&out2, "secret", "label", "seed B");

    try std.testing.expect(!std.mem.eql(u8, &out1, &out2));
}

test "TLS 1.2 PRF large output" {
    const Crypto = runtime.std.Crypto;

    var out: [104]u8 = undefined;
    Tls12Prf(Crypto).prf(&out, "master secret", "key expansion", "server_random" ++ "client_random");

    const all_zero = std.mem.allEqual(u8, &out, 0);
    try std.testing.expect(!all_zero);
}

test "KeyExchange X25519 generate and public key" {
    const Crypto = runtime.std.Crypto;

    var kx = try KeyExchange(Crypto).generate(.x25519, &testRngFill);
    const pub_key = kx.publicKey();
    try std.testing.expectEqual(@as(usize, 32), pub_key.len);

    const all_zero = std.mem.allEqual(u8, pub_key, 0);
    try std.testing.expect(!all_zero);
}

test "KeyExchange unsupported group" {
    const Crypto = runtime.std.Crypto;

    try std.testing.expectError(
        error.UnsupportedGroup,
        KeyExchange(Crypto).generate(.x448, &testRngFill),
    );
}

test "X25519 shared secret computation" {
    const Crypto = runtime.std.Crypto;

    var kx_a = try KeyExchange(Crypto).generate(.x25519, &testRngFill);
    var kx_b = try KeyExchange(Crypto).generate(.x25519, &testRngFill);

    const shared_a = try kx_a.computeSharedSecret(kx_b.publicKey());
    const shared_b = try kx_b.computeSharedSecret(kx_a.publicKey());

    try std.testing.expectEqualSlices(u8, shared_a, shared_b);
}

test "X25519 invalid public key length" {
    const Crypto = runtime.std.Crypto;

    var kx = try KeyExchange(Crypto).generate(.x25519, &testRngFill);
    const short_key: [16]u8 = [_]u8{0} ** 16;
    try std.testing.expectError(error.InvalidPublicKey, kx.computeSharedSecret(&short_key));
}

test "ClientHandshake init fills client_random" {
    const Crypto = runtime.std.Crypto;
    const conn_mod = embed.pkg.net.conn;

    const MockConn2 = struct {
        const Self = @This();
        pub fn read(_: *Self, _: []u8) conn_mod.Error!usize {
            return 0;
        }
        pub fn write(_: *Self, _: []const u8) conn_mod.Error!usize {
            return 0;
        }
        pub fn close(_: *Self) void {}
    };

    var conn = MockConn2{};
    const hs = ClientHandshake(MockConn2, Crypto).init(&conn, "test.com", std.testing.allocator, null, &testRngFill);

    const all_zero = std.mem.allEqual(u8, &hs.client_random, 0);
    try std.testing.expect(!all_zero);
}

test "ClientHandshake initial state" {
    const Crypto = runtime.std.Crypto;
    const conn_mod = embed.pkg.net.conn;

    const MockConn3 = struct {
        const Self = @This();
        pub fn read(_: *Self, _: []u8) conn_mod.Error!usize {
            return 0;
        }
        pub fn write(_: *Self, _: []const u8) conn_mod.Error!usize {
            return 0;
        }
        pub fn close(_: *Self) void {}
    };

    var conn = MockConn3{};
    const hs = ClientHandshake(MockConn3, Crypto).init(&conn, "host.example.com", std.testing.allocator, null, &testRngFill);

    try std.testing.expectEqual(HandshakeState.initial, hs.state);
    try std.testing.expectEqual(ProtocolVersion.tls_1_3, hs.version);
    try std.testing.expectEqual(CipherSuite.TLS_AES_128_GCM_SHA256, hs.cipher_suite);
    try std.testing.expect(hs.key_exchange == null);
    try std.testing.expectEqual(@as(u8, 0), hs.tls12_server_pubkey_len);
    try std.testing.expectEqual(@as(u16, 0), hs.server_cert_der_len);
}

test "HandshakeState enum values" {
    const states = [_]HandshakeState{
        .initial,
        .wait_server_hello,
        .wait_encrypted_extensions,
        .wait_certificate,
        .wait_certificate_verify,
        .wait_finished,
        .connected,
        .error_state,
        .wait_server_key_exchange,
        .wait_server_hello_done,
    };
    for (states, 0..) |s, i| {
        for (states, 0..) |s2, j| {
            if (i == j) {
                try std.testing.expectEqual(s, s2);
            } else {
                try std.testing.expect(s != s2);
            }
        }
    }
}
