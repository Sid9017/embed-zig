const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const Std = embed.runtime.std;
const record = embed.pkg.net.tls.record;
const tls_common = embed.pkg.net.tls.common;
const conn_mod = embed.pkg.net.conn;

const MockConn = struct {
    write_buf: [16384]u8 = undefined,
    write_len: usize = 0,
    read_buf: [16384]u8 = undefined,
    read_len: usize = 0,
    read_pos: usize = 0,
    closed: bool = false,

    pub fn read(self: *MockConn, buf: []u8) conn_mod.Error!usize {
        if (self.closed) return conn_mod.Error.Closed;
        if (self.read_pos >= self.read_len) return conn_mod.Error.ReadFailed;
        const avail = self.read_len - self.read_pos;
        const n = @min(avail, buf.len);
        @memcpy(buf[0..n], self.read_buf[self.read_pos..][0..n]);
        self.read_pos += n;
        return n;
    }

    pub fn write(self: *MockConn, data: []const u8) conn_mod.Error!usize {
        if (self.closed) return conn_mod.Error.Closed;
        const space = self.write_buf.len - self.write_len;
        const n = @min(space, data.len);
        if (n == 0) return conn_mod.Error.WriteFailed;
        @memcpy(self.write_buf[self.write_len..][0..n], data[0..n]);
        self.write_len += n;
        return n;
    }

    pub fn close(self: *MockConn) void {
        self.closed = true;
    }

    pub fn feedData(self: *MockConn, data: []const u8) void {
        @memcpy(self.read_buf[0..data.len], data);
        self.read_len = data.len;
        self.read_pos = 0;
    }
};

test "RecordHeader parse and serialize" {
    const header = record.RecordHeader{
        .content_type = .handshake,
        .legacy_version = .tls_1_2,
        .length = 256,
    };

    var buf: [5]u8 = undefined;
    try header.serialize(&buf);

    const parsed = try record.RecordHeader.parse(&buf);
    try std.testing.expectEqual(header.content_type, parsed.content_type);
    try std.testing.expectEqual(header.legacy_version, parsed.legacy_version);
    try std.testing.expectEqual(header.length, parsed.length);
}

test "CipherState initialization" {
    const Runtime = Std;

    const key_128: [16]u8 = [_]u8{0} ** 16;
    const iv: [12]u8 = [_]u8{0} ** 12;

    const state = try record.CipherState(Runtime).init(.TLS_AES_128_GCM_SHA256, &key_128, &iv);
    try std.testing.expect(state == .aes_128_gcm);
}

test "AES-128-GCM encrypt/decrypt round trip" {
    const Runtime = Std;

    const key: [16]u8 = [_]u8{0x01} ** 16;
    const iv: [12]u8 = [_]u8{0x02} ** 12;
    const plaintext = "Hello, TLS Record Layer!";
    const ad = "additional data";

    var state = try record.AesGcmState(Runtime, 16).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, ad, 0);

    var decrypted: [plaintext.len]u8 = undefined;
    try state.decrypt(&decrypted, &ciphertext, tag, ad, 0);

    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "ChaCha20-Poly1305 encrypt/decrypt round trip" {
    const Runtime = Std;

    const key: [32]u8 = [_]u8{0x05} ** 32;
    const iv: [12]u8 = [_]u8{0x06} ** 12;
    const plaintext = "ChaCha20-Poly1305 record test";
    const ad = "associated data";

    var state = try record.ChaChaState(Runtime).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, ad, 0);

    var decrypted: [plaintext.len]u8 = undefined;
    try state.decrypt(&decrypted, &ciphertext, tag, ad, 0);

    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "Decryption with wrong sequence number fails" {
    const Runtime = Std;

    const key: [16]u8 = [_]u8{0x07} ** 16;
    const iv: [12]u8 = [_]u8{0x08} ** 12;
    const plaintext = "Sequence number test";
    const ad = "aad";

    var state = try record.AesGcmState(Runtime, 16).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, ad, 5);

    var decrypted: [plaintext.len]u8 = undefined;
    const result = state.decrypt(&decrypted, &ciphertext, tag, ad, 6);
    try std.testing.expectError(error.AuthenticationFailed, result);

    try state.decrypt(&decrypted, &ciphertext, tag, ad, 5);
    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "CipherState unsupported cipher suite" {
    const Runtime = Std;

    const key: [16]u8 = [_]u8{0} ** 16;
    const iv: [12]u8 = [_]u8{0} ** 12;

    const unknown_suite: tls_common.CipherSuite = @enumFromInt(0xFFFF);
    const result = record.CipherState(Runtime).init(unknown_suite, &key, &iv);
    try std.testing.expectError(error.UnsupportedCipherSuite, result);
}

test "AES-256-GCM encrypt/decrypt round trip" {
    const Runtime = Std;

    const key: [32]u8 = [_]u8{0xAB} ** 32;
    const iv: [12]u8 = [_]u8{0xCD} ** 12;
    const plaintext = "AES-256-GCM test payload for TLS";
    const ad = "aes256 additional data";

    var state = try record.AesGcmState(Runtime, 32).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, ad, 0);

    var decrypted: [plaintext.len]u8 = undefined;
    try state.decrypt(&decrypted, &ciphertext, tag, ad, 0);
    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "CipherState init all supported suites" {
    const Runtime = Std;

    const key16: [16]u8 = [_]u8{0} ** 16;
    const key32: [32]u8 = [_]u8{0} ** 32;
    const iv: [12]u8 = [_]u8{0} ** 12;

    const suites_16 = [_]tls_common.CipherSuite{
        .TLS_AES_128_GCM_SHA256,
        .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
        .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
    };
    for (suites_16) |suite| {
        const s = try record.CipherState(Runtime).init(suite, &key16, &iv);
        try std.testing.expect(s == .aes_128_gcm);
    }

    const suites_32_aes = [_]tls_common.CipherSuite{
        .TLS_AES_256_GCM_SHA384,
        .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
        .TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
    };
    for (suites_32_aes) |suite| {
        const s = try record.CipherState(Runtime).init(suite, &key32, &iv);
        try std.testing.expect(s == .aes_256_gcm);
    }

    const suites_chacha = [_]tls_common.CipherSuite{
        .TLS_CHACHA20_POLY1305_SHA256,
        .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
        .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
    };
    for (suites_chacha) |suite| {
        const s = try record.CipherState(Runtime).init(suite, &key32, &iv);
        try std.testing.expect(s == .chacha20_poly1305);
    }
}

test "AesGcmState invalid key length" {
    const Runtime = Std;

    const bad_key: [15]u8 = [_]u8{0} ** 15;
    const iv: [12]u8 = [_]u8{0} ** 12;
    try std.testing.expectError(error.InvalidKeyLength, record.AesGcmState(Runtime, 16).init(&bad_key, &iv));
}

test "AesGcmState invalid IV length" {
    const Runtime = Std;

    const key: [16]u8 = [_]u8{0} ** 16;
    const bad_iv: [8]u8 = [_]u8{0} ** 8;
    try std.testing.expectError(error.InvalidIvLength, record.AesGcmState(Runtime, 16).init(&key, &bad_iv));
}

test "ChaChaState invalid key length" {
    const Runtime = Std;

    const bad_key: [16]u8 = [_]u8{0} ** 16;
    const iv: [12]u8 = [_]u8{0} ** 12;
    try std.testing.expectError(error.InvalidKeyLength, record.ChaChaState(Runtime).init(&bad_key, &iv));
}

test "ChaChaState invalid IV length" {
    const Runtime = Std;

    const key: [32]u8 = [_]u8{0} ** 32;
    const bad_iv: [8]u8 = [_]u8{0} ** 8;
    try std.testing.expectError(error.InvalidIvLength, record.ChaChaState(Runtime).init(&key, &bad_iv));
}

test "AES-128-GCM TLS 1.2 explicit nonce encrypt/decrypt" {
    const Runtime = Std;

    const key: [16]u8 = [_]u8{0x11} ** 16;
    const iv: [12]u8 = [_]u8{0x22} ** 12;
    const plaintext = "TLS 1.2 explicit nonce test";
    const ad = "tls12 aad";
    var explicit_nonce: [8]u8 = undefined;
    std.mem.writeInt(u64, &explicit_nonce, 42, .big);

    var state = try record.AesGcmState(Runtime, 16).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encryptTls12(&ciphertext, &tag, plaintext, ad, &explicit_nonce);

    var decrypted: [plaintext.len]u8 = undefined;
    try state.decryptTls12(&decrypted, &ciphertext, tag, ad, &explicit_nonce);
    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "ChaCha20 TLS 1.2 explicit nonce encrypt/decrypt" {
    const Runtime = Std;

    const key: [32]u8 = [_]u8{0x33} ** 32;
    const iv: [12]u8 = [_]u8{0x44} ** 12;
    const plaintext = "ChaCha TLS 1.2 nonce test";
    const ad = "chacha tls12 aad";
    var explicit_nonce: [8]u8 = undefined;
    std.mem.writeInt(u64, &explicit_nonce, 99, .big);

    var state = try record.ChaChaState(Runtime).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encryptTls12(&ciphertext, &tag, plaintext, ad, &explicit_nonce);

    var decrypted: [plaintext.len]u8 = undefined;
    try state.decryptTls12(&decrypted, &ciphertext, tag, ad, &explicit_nonce);
    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "Decryption with tampered ciphertext fails" {
    const Runtime = Std;

    const key: [16]u8 = [_]u8{0xAA} ** 16;
    const iv: [12]u8 = [_]u8{0xBB} ** 12;
    const plaintext = "tamper test";
    const ad = "aad";

    var state = try record.AesGcmState(Runtime, 16).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, ad, 0);

    ciphertext[0] ^= 0xFF;

    var decrypted: [plaintext.len]u8 = undefined;
    try std.testing.expectError(error.AuthenticationFailed, state.decrypt(&decrypted, &ciphertext, tag, ad, 0));
}

test "Decryption with tampered tag fails" {
    const Runtime = Std;

    const key: [32]u8 = [_]u8{0xCC} ** 32;
    const iv: [12]u8 = [_]u8{0xDD} ** 12;
    const plaintext = "tag tamper test";
    const ad = "aad";

    var state = try record.AesGcmState(Runtime, 32).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, ad, 0);

    tag[0] ^= 0xFF;

    var decrypted: [plaintext.len]u8 = undefined;
    try std.testing.expectError(error.AuthenticationFailed, state.decrypt(&decrypted, &ciphertext, tag, ad, 0));
}

test "Decryption with wrong additional data fails" {
    const Runtime = Std;

    const key: [16]u8 = [_]u8{0xEE} ** 16;
    const iv: [12]u8 = [_]u8{0xFF} ** 12;
    const plaintext = "ad tamper test";

    var state = try record.AesGcmState(Runtime, 16).init(&key, &iv);

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    state.encrypt(&ciphertext, &tag, plaintext, "correct ad", 0);

    var decrypted: [plaintext.len]u8 = undefined;
    try std.testing.expectError(error.AuthenticationFailed, state.decrypt(&decrypted, &ciphertext, tag, "wrong ad", 0));
}

test "Nonce computation XORs sequence number correctly" {
    const Runtime = Std;

    const key: [16]u8 = [_]u8{0} ** 16;
    const iv: [12]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const plaintext = "nonce xor test";
    const ad = "aad";

    var state0 = try record.AesGcmState(Runtime, 16).init(&key, &iv);
    var state1 = try record.AesGcmState(Runtime, 16).init(&key, &iv);

    var ct0: [plaintext.len]u8 = undefined;
    var tag0: [16]u8 = undefined;
    state0.encrypt(&ct0, &tag0, plaintext, ad, 0);

    var ct1: [plaintext.len]u8 = undefined;
    var tag1: [16]u8 = undefined;
    state1.encrypt(&ct1, &tag1, plaintext, ad, 1);

    try std.testing.expect(!std.mem.eql(u8, &ct0, &ct1));
}

test "RecordHeader parse too small buffer" {
    const buf: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, record.RecordHeader.parse(&buf));
}

test "RecordHeader serialize too small buffer" {
    const header = record.RecordHeader{
        .content_type = .handshake,
        .legacy_version = .tls_1_2,
        .length = 0,
    };
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, header.serialize(&buf));
}

test "RecordHeader all content types" {
    const types = [_]tls_common.ContentType{ .change_cipher_spec, .alert, .handshake, .application_data };
    for (types) |ct| {
        const header = record.RecordHeader{
            .content_type = ct,
            .legacy_version = .tls_1_3,
            .length = 100,
        };
        var buf: [5]u8 = undefined;
        try header.serialize(&buf);
        const parsed = try record.RecordHeader.parse(&buf);
        try std.testing.expectEqual(ct, parsed.content_type);
    }
}

test "RecordHeader max length" {
    const header = record.RecordHeader{
        .content_type = .application_data,
        .legacy_version = .tls_1_2,
        .length = 0xFFFF,
    };
    var buf: [5]u8 = undefined;
    try header.serialize(&buf);
    const parsed = try record.RecordHeader.parse(&buf);
    try std.testing.expectEqual(@as(u16, 0xFFFF), parsed.length);
}

test "RecordLayer plaintext write and read round trip" {
    const Runtime = Std;

    var mock = MockConn{};
    var rl = record.RecordLayer(MockConn, Runtime).init(&mock);

    const plaintext = "hello record layer";
    var buffer: [256]u8 = undefined;
    const written = try rl.writeRecord(.application_data, plaintext, &buffer);
    try std.testing.expect(written > 0);

    mock.feedData(mock.write_buf[0..mock.write_len]);
    mock.write_len = 0;

    var read_buf: [256]u8 = undefined;
    var pt_out: [256]u8 = undefined;
    const result = try rl.readRecord(&read_buf, &pt_out);
    try std.testing.expectEqual(tls_common.ContentType.application_data, result.content_type);
    try std.testing.expectEqual(plaintext.len, result.length);
    try std.testing.expectEqualSlices(u8, plaintext, pt_out[0..result.length]);
}

test "RecordLayer encrypted TLS 1.3 write and read round trip" {
    const Runtime = Std;

    var mock = MockConn{};
    var rl = record.RecordLayer(MockConn, Runtime).init(&mock);
    rl.version = .tls_1_3;

    const key: [16]u8 = [_]u8{0x42} ** 16;
    const iv: [12]u8 = [_]u8{0x43} ** 12;
    const write_cipher = try record.CipherState(Runtime).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    const read_cipher = try record.CipherState(Runtime).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    rl.setWriteCipher(write_cipher);

    const plaintext = "encrypted TLS 1.3 payload";
    var buffer: [512]u8 = undefined;
    _ = try rl.writeRecord(.application_data, plaintext, &buffer);

    mock.feedData(mock.write_buf[0..mock.write_len]);
    mock.write_len = 0;

    rl.setReadCipher(read_cipher);

    var read_buf: [512]u8 = undefined;
    var pt_out: [512]u8 = undefined;
    const result = try rl.readRecord(&read_buf, &pt_out);
    try std.testing.expectEqual(tls_common.ContentType.application_data, result.content_type);
    try std.testing.expectEqual(plaintext.len, result.length);
    try std.testing.expectEqualSlices(u8, plaintext, pt_out[0..result.length]);
}

test "RecordLayer encrypted TLS 1.2 write and read round trip" {
    const Runtime = Std;

    var mock = MockConn{};
    var rl = record.RecordLayer(MockConn, Runtime).init(&mock);
    rl.version = .tls_1_2;

    const key: [16]u8 = [_]u8{0x50} ** 16;
    const iv: [12]u8 = [_]u8{0x51} ** 12;
    const write_cipher = try record.CipherState(Runtime).init(.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, &key, &iv);
    const read_cipher = try record.CipherState(Runtime).init(.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, &key, &iv);
    rl.setWriteCipher(write_cipher);

    const plaintext = "encrypted TLS 1.2 payload";
    var buffer: [512]u8 = undefined;
    _ = try rl.writeRecord(.application_data, plaintext, &buffer);

    mock.feedData(mock.write_buf[0..mock.write_len]);
    mock.write_len = 0;

    rl.setReadCipher(read_cipher);

    var read_buf: [512]u8 = undefined;
    var pt_out: [512]u8 = undefined;
    const result = try rl.readRecord(&read_buf, &pt_out);
    try std.testing.expectEqual(tls_common.ContentType.application_data, result.content_type);
    try std.testing.expectEqual(plaintext.len, result.length);
    try std.testing.expectEqualSlices(u8, plaintext, pt_out[0..result.length]);
}

test "RecordLayer rejects record too large" {
    const Runtime = Std;

    var mock = MockConn{};
    var rl = record.RecordLayer(MockConn, Runtime).init(&mock);

    var big_data: [tls_common.MAX_PLAINTEXT_LEN + 1]u8 = undefined;
    @memset(&big_data, 0x41);
    var buffer: [tls_common.MAX_CIPHERTEXT_LEN + 256]u8 = undefined;
    try std.testing.expectError(error.RecordTooLarge, rl.writeRecord(.application_data, &big_data, &buffer));
}

test "RecordLayer sendAlert" {
    const Runtime = Std;

    var mock = MockConn{};
    var rl = record.RecordLayer(MockConn, Runtime).init(&mock);

    var buffer: [256]u8 = undefined;
    try rl.sendAlert(.fatal, .handshake_failure, &buffer);

    try std.testing.expect(mock.write_len > 0);

    mock.feedData(mock.write_buf[0..mock.write_len]);
    var read_buf: [256]u8 = undefined;
    var pt_out: [256]u8 = undefined;
    const result = try rl.readRecord(&read_buf, &pt_out);
    try std.testing.expectEqual(tls_common.ContentType.alert, result.content_type);
    try std.testing.expectEqual(@as(usize, 2), result.length);
    try std.testing.expectEqual(@as(u8, @intFromEnum(tls_common.AlertLevel.fatal)), pt_out[0]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(tls_common.AlertDescription.handshake_failure)), pt_out[1]);
}

test "RecordLayer change_cipher_spec passthrough" {
    const Runtime = Std;

    var mock = MockConn{};
    var rl = record.RecordLayer(MockConn, Runtime).init(&mock);

    const ccs_payload = [_]u8{1};
    var buffer: [256]u8 = undefined;
    _ = try rl.writeRecord(.change_cipher_spec, &ccs_payload, &buffer);

    mock.feedData(mock.write_buf[0..mock.write_len]);
    mock.write_len = 0;

    var read_buf: [256]u8 = undefined;
    var pt_out: [256]u8 = undefined;
    const result = try rl.readRecord(&read_buf, &pt_out);
    try std.testing.expectEqual(tls_common.ContentType.change_cipher_spec, result.content_type);
    try std.testing.expectEqual(@as(usize, 1), result.length);
    try std.testing.expectEqual(@as(u8, 1), pt_out[0]);
}

test "RecordLayer sequence numbers increment" {
    const Runtime = Std;

    var mock = MockConn{};
    var rl = record.RecordLayer(MockConn, Runtime).init(&mock);
    rl.version = .tls_1_3;

    const key: [16]u8 = [_]u8{0x60} ** 16;
    const iv: [12]u8 = [_]u8{0x61} ** 12;
    const cipher = try record.CipherState(Runtime).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    rl.setWriteCipher(cipher);

    try std.testing.expectEqual(@as(u64, 0), rl.write_seq);

    var buffer: [512]u8 = undefined;
    _ = try rl.writeRecord(.application_data, "msg1", &buffer);
    try std.testing.expectEqual(@as(u64, 1), rl.write_seq);

    mock.write_len = 0;
    _ = try rl.writeRecord(.application_data, "msg2", &buffer);
    try std.testing.expectEqual(@as(u64, 2), rl.write_seq);
}

test "RecordLayer setWriteCipher resets sequence" {
    const Runtime = Std;

    var mock = MockConn{};
    var rl = record.RecordLayer(MockConn, Runtime).init(&mock);
    rl.version = .tls_1_3;

    const key: [16]u8 = [_]u8{0x70} ** 16;
    const iv: [12]u8 = [_]u8{0x71} ** 12;
    var cipher = try record.CipherState(Runtime).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    rl.setWriteCipher(cipher);

    var buffer: [512]u8 = undefined;
    _ = try rl.writeRecord(.application_data, "msg", &buffer);
    try std.testing.expectEqual(@as(u64, 1), rl.write_seq);

    cipher = try record.CipherState(Runtime).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    rl.setWriteCipher(cipher);
    try std.testing.expectEqual(@as(u64, 0), rl.write_seq);
}
