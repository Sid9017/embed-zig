const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const Std = embed.runtime.std;
const handshake = embed.pkg.net.tls.handshake;
const tls_common = embed.pkg.net.tls.common;

test "HandshakeHeader parse and serialize" {
    const header = handshake.HandshakeHeader{
        .msg_type = .client_hello,
        .length = 256,
    };

    var buf: [4]u8 = undefined;
    try header.serialize(&buf);

    const parsed = try handshake.HandshakeHeader.parse(&buf);
    try std.testing.expectEqual(header.msg_type, parsed.msg_type);
    try std.testing.expectEqual(header.length, parsed.length);
}

test "TranscriptHash" {
    const Runtime = Std;

    var hash = handshake.TranscriptHash(Runtime).init();
    hash.update("hello");
    hash.update("world");

    const result1 = hash.peek();
    const result2 = hash.peek();

    try std.testing.expectEqual(result1, result2);
}

test "TLS 1.2 PRF basic" {
    const Runtime = Std;

    const secret = "secret";
    const label = "test label";
    const seed = "seed";

    var out: [32]u8 = undefined;
    handshake.Tls12Prf(Runtime).prf(&out, secret, label, seed);

    var out2: [32]u8 = undefined;
    handshake.Tls12Prf(Runtime).prf(&out2, secret, label, seed);
    try std.testing.expectEqualSlices(u8, &out, &out2);

    var out3: [32]u8 = undefined;
    handshake.Tls12Prf(Runtime).prf(&out3, "different", label, seed);
    try std.testing.expect(!std.mem.eql(u8, &out, &out3));
}

test "TLS 1.2 PRF output length" {
    const Runtime = Std;

    const secret = "secret";
    const label = "label";
    const seed = "seed";

    var out12: [12]u8 = undefined;
    handshake.Tls12Prf(Runtime).prf(&out12, secret, label, seed);

    var out48: [48]u8 = undefined;
    handshake.Tls12Prf(Runtime).prf(&out48, secret, label, seed);

    try std.testing.expectEqualSlices(u8, &out12, out48[0..12]);
}

test "ClientHandshake init with Conn" {
    const Runtime = Std;
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
    const Hs = handshake.ClientHandshake(MockConn, Runtime);

    const hs = try Hs.init(&conn, "example.com", std.testing.allocator, false, Runtime.Rng.init());

    try std.testing.expectEqualStrings("example.com", hs.hostname);
    try std.testing.expect(hs.state == .initial);
}

test "HandshakeHeader parse too small buffer" {
    const buf: [3]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, handshake.HandshakeHeader.parse(&buf));
}

test "HandshakeHeader serialize too small buffer" {
    const header = handshake.HandshakeHeader{ .msg_type = .client_hello, .length = 0 };
    var buf: [3]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, header.serialize(&buf));
}

test "HandshakeHeader all message types roundtrip" {
    const types_to_test = [_]tls_common.HandshakeType{
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
        const header = handshake.HandshakeHeader{ .msg_type = mt, .length = 12345 };
        var buf: [4]u8 = undefined;
        try header.serialize(&buf);
        const parsed = try handshake.HandshakeHeader.parse(&buf);
        try std.testing.expectEqual(mt, parsed.msg_type);
        try std.testing.expectEqual(@as(u24, 12345), parsed.length);
    }
}

test "HandshakeHeader max length" {
    const header = handshake.HandshakeHeader{ .msg_type = .client_hello, .length = std.math.maxInt(u24) };
    var buf: [4]u8 = undefined;
    try header.serialize(&buf);
    const parsed = try handshake.HandshakeHeader.parse(&buf);
    try std.testing.expectEqual(std.math.maxInt(u24), parsed.length);
}

test "TranscriptHash final differs from peek after more updates" {
    const Runtime = Std;

    var hash = handshake.TranscriptHash(Runtime).init();
    hash.update("part1");
    const peeked = hash.peek();

    hash.update("part2");
    const peeked2 = hash.peek();

    try std.testing.expect(!std.mem.eql(u8, &peeked, &peeked2));
}

test "TranscriptHash empty input" {
    const Runtime = Std;

    var hash = handshake.TranscriptHash(Runtime).init();
    const result = hash.peek();

    var expected: [32]u8 = undefined;
    Runtime.Crypto.Hash.Sha256().hash("", &expected);
    try std.testing.expectEqualSlices(u8, &expected, &result);
}

test "TLS 1.2 PRF different labels produce different output" {
    const Runtime = Std;

    var out1: [32]u8 = undefined;
    handshake.Tls12Prf(Runtime).prf(&out1, "secret", "label A", "seed");

    var out2: [32]u8 = undefined;
    handshake.Tls12Prf(Runtime).prf(&out2, "secret", "label B", "seed");

    try std.testing.expect(!std.mem.eql(u8, &out1, &out2));
}

test "TLS 1.2 PRF different seeds produce different output" {
    const Runtime = Std;

    var out1: [32]u8 = undefined;
    handshake.Tls12Prf(Runtime).prf(&out1, "secret", "label", "seed A");

    var out2: [32]u8 = undefined;
    handshake.Tls12Prf(Runtime).prf(&out2, "secret", "label", "seed B");

    try std.testing.expect(!std.mem.eql(u8, &out1, &out2));
}

test "TLS 1.2 PRF large output" {
    const Runtime = Std;

    var out: [104]u8 = undefined;
    handshake.Tls12Prf(Runtime).prf(&out, "master secret", "key expansion", "server_random" ++ "client_random");

    const all_zero = std.mem.allEqual(u8, &out, 0);
    try std.testing.expect(!all_zero);
}

test "KeyExchange X25519 generate and public key" {
    const Runtime = Std;

    var kx = try handshake.KeyExchange(Runtime).generate(.x25519, Runtime.Rng.init());
    const pub_key = kx.publicKey();
    try std.testing.expectEqual(@as(usize, 32), pub_key.len);

    const all_zero = std.mem.allEqual(u8, pub_key, 0);
    try std.testing.expect(!all_zero);
}

test "KeyExchange unsupported group" {
    const Runtime = Std;

    try std.testing.expectError(
        error.UnsupportedGroup,
        handshake.KeyExchange(Runtime).generate(.x448, Runtime.Rng.init()),
    );
}

test "X25519 shared secret computation" {
    const Runtime = Std;

    var kx_a = try handshake.KeyExchange(Runtime).generate(.x25519, Runtime.Rng.init());
    var kx_b = try handshake.KeyExchange(Runtime).generate(.x25519, Runtime.Rng.init());

    const shared_a = try kx_a.computeSharedSecret(kx_b.publicKey());
    const shared_b = try kx_b.computeSharedSecret(kx_a.publicKey());

    try std.testing.expectEqualSlices(u8, shared_a, shared_b);
}

test "X25519 invalid public key length" {
    const Runtime = Std;

    var kx = try handshake.KeyExchange(Runtime).generate(.x25519, Runtime.Rng.init());
    const short_key: [16]u8 = [_]u8{0} ** 16;
    try std.testing.expectError(error.InvalidPublicKey, kx.computeSharedSecret(&short_key));
}

test "ClientHandshake init fills client_random" {
    const Runtime = Std;
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
    const hs = try handshake.ClientHandshake(MockConn2, Runtime).init(&conn, "test.com", std.testing.allocator, false, Runtime.Rng.init());

    const all_zero = std.mem.allEqual(u8, &hs.client_random, 0);
    try std.testing.expect(!all_zero);
}

test "ClientHandshake initial state" {
    const Runtime = Std;
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
    const hs = try handshake.ClientHandshake(MockConn3, Runtime).init(&conn, "host.example.com", std.testing.allocator, false, Runtime.Rng.init());

    try std.testing.expectEqual(handshake.HandshakeState.initial, hs.state);
    try std.testing.expectEqual(tls_common.ProtocolVersion.tls_1_3, hs.version);
    try std.testing.expectEqual(tls_common.CipherSuite.TLS_AES_128_GCM_SHA256, hs.cipher_suite);
    try std.testing.expect(hs.key_exchange == null);
    try std.testing.expectEqual(@as(u8, 0), hs.tls12_server_pubkey_len);
    try std.testing.expectEqual(@as(u16, 0), hs.server_cert_der_len);
}

test "HandshakeState enum values" {
    const states = [_]handshake.HandshakeState{
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
