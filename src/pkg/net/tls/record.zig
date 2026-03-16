const std = @import("std");
const crypto_suite = @import("../../../runtime/crypto/suite.zig");
pub const common = @import("common.zig");

pub const ContentType = common.ContentType;
pub const ProtocolVersion = common.ProtocolVersion;
pub const CipherSuite = common.CipherSuite;
pub const AlertDescription = common.AlertDescription;
pub const AlertLevel = common.AlertLevel;

pub const RecordHeader = struct {
    content_type: ContentType,
    legacy_version: ProtocolVersion,
    length: u16,

    pub const SIZE = 5;

    pub fn parse(buf: []const u8) !RecordHeader {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return RecordHeader{
            .content_type = @enumFromInt(buf[0]),
            .legacy_version = @enumFromInt(std.mem.readInt(u16, buf[1..3], .big)),
            .length = std.mem.readInt(u16, buf[3..5], .big),
        };
    }

    pub fn serialize(self: RecordHeader, buf: []u8) !void {
        if (buf.len < SIZE) return error.BufferTooSmall;
        buf[0] = @intFromEnum(self.content_type);
        std.mem.writeInt(u16, buf[1..3], @intFromEnum(self.legacy_version), .big);
        std.mem.writeInt(u16, buf[3..5], self.length, .big);
    }
};

pub fn CipherState(comptime Crypto: type) type {
    comptime {
        _ = crypto_suite.is(Crypto);
    }
    return union(enum) {
        none,
        aes_128_gcm: AesGcmState(Crypto, 16),
        aes_256_gcm: AesGcmState(Crypto, 32),
        chacha20_poly1305: ChaChaState(Crypto),

        const Self = @This();

        pub fn init(suite: CipherSuite, key: []const u8, iv: []const u8) !Self {
            return switch (suite) {
                .TLS_AES_128_GCM_SHA256,
                .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
                => .{ .aes_128_gcm = try AesGcmState(Crypto, 16).init(key, iv) },

                .TLS_AES_256_GCM_SHA384,
                .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
                .TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
                => .{ .aes_256_gcm = try AesGcmState(Crypto, 32).init(key, iv) },

                .TLS_CHACHA20_POLY1305_SHA256,
                .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
                => .{ .chacha20_poly1305 = try ChaChaState(Crypto).init(key, iv) },

                else => return error.UnsupportedCipherSuite,
            };
        }
    };
}

pub fn AesGcmState(comptime Crypto: type, comptime key_len: usize) type {
    comptime {
        _ = crypto_suite.is(Crypto);
    }
    return struct {
        key: [key_len]u8,
        iv: [12]u8,

        const Self = @This();
        const AEAD = if (key_len == 16) Crypto.Aead.Aes128Gcm() else Crypto.Aead.Aes256Gcm();

        pub fn init(key: []const u8, iv: []const u8) !Self {
            if (key.len != key_len) return error.InvalidKeyLength;
            if (iv.len != 12) return error.InvalidIvLength;
            var self: Self = undefined;
            @memcpy(&self.key, key);
            @memcpy(&self.iv, iv);
            return self;
        }

        pub fn encrypt(self: *Self, ciphertext: []u8, tag: *[16]u8, plaintext: []const u8, additional_data: []const u8, seq_num: u64) void {
            const nonce = self.computeNonce(seq_num);
            AEAD.encryptStatic(ciphertext, tag, plaintext, additional_data, nonce, self.key);
        }

        pub fn encryptTls12(self: *Self, ciphertext: []u8, tag: *[16]u8, plaintext: []const u8, additional_data: []const u8, explicit_nonce: *const [8]u8) void {
            var nonce: [12]u8 = undefined;
            @memcpy(nonce[0..4], self.iv[0..4]);
            @memcpy(nonce[4..12], explicit_nonce);
            AEAD.encryptStatic(ciphertext, tag, plaintext, additional_data, nonce, self.key);
        }

        pub fn decrypt(self: *Self, plaintext: []u8, ciphertext: []const u8, tag: [16]u8, additional_data: []const u8, seq_num: u64) !void {
            const nonce = self.computeNonce(seq_num);
            try AEAD.decryptStatic(plaintext, ciphertext, tag, additional_data, nonce, self.key);
        }

        pub fn decryptTls12(self: *Self, plaintext: []u8, ciphertext: []const u8, tag: [16]u8, additional_data: []const u8, explicit_nonce: *const [8]u8) !void {
            var nonce: [12]u8 = undefined;
            @memcpy(nonce[0..4], self.iv[0..4]);
            @memcpy(nonce[4..12], explicit_nonce);
            try AEAD.decryptStatic(plaintext, ciphertext, tag, additional_data, nonce, self.key);
        }

        fn computeNonce(self: *Self, seq_num: u64) [12]u8 {
            var nonce = self.iv;
            const seq_bytes = std.mem.toBytes(std.mem.nativeToBig(u64, seq_num));
            for (0..8) |i| {
                nonce[4 + i] ^= seq_bytes[i];
            }
            return nonce;
        }
    };
}

pub fn ChaChaState(comptime Crypto: type) type {
    comptime {
        _ = crypto_suite.is(Crypto);
    }
    return struct {
        key: [32]u8,
        iv: [12]u8,

        const Self = @This();
        const AEAD = Crypto.Aead.ChaCha20Poly1305();

        pub fn init(key: []const u8, iv: []const u8) !Self {
            if (key.len != 32) return error.InvalidKeyLength;
            if (iv.len != 12) return error.InvalidIvLength;
            var self: Self = undefined;
            @memcpy(&self.key, key);
            @memcpy(&self.iv, iv);
            return self;
        }

        pub fn encrypt(self: *Self, ciphertext: []u8, tag: *[16]u8, plaintext: []const u8, additional_data: []const u8, seq_num: u64) void {
            const nonce = self.computeNonce(seq_num);
            AEAD.encryptStatic(ciphertext, tag, plaintext, additional_data, nonce, self.key);
        }

        pub fn encryptTls12(self: *Self, ciphertext: []u8, tag: *[16]u8, plaintext: []const u8, additional_data: []const u8, explicit_nonce: *const [8]u8) void {
            var nonce: [12]u8 = self.iv;
            for (0..8) |i| {
                nonce[4 + i] ^= explicit_nonce[i];
            }
            AEAD.encryptStatic(ciphertext, tag, plaintext, additional_data, nonce, self.key);
        }

        pub fn decrypt(self: *Self, plaintext: []u8, ciphertext: []const u8, tag: [16]u8, additional_data: []const u8, seq_num: u64) !void {
            const nonce = self.computeNonce(seq_num);
            try AEAD.decryptStatic(plaintext, ciphertext, tag, additional_data, nonce, self.key);
        }

        pub fn decryptTls12(self: *Self, plaintext: []u8, ciphertext: []const u8, tag: [16]u8, additional_data: []const u8, explicit_nonce: *const [8]u8) !void {
            var nonce: [12]u8 = self.iv;
            for (0..8) |i| {
                nonce[4 + i] ^= explicit_nonce[i];
            }
            try AEAD.decryptStatic(plaintext, ciphertext, tag, additional_data, nonce, self.key);
        }

        fn computeNonce(self: *Self, seq_num: u64) [12]u8 {
            var nonce = self.iv;
            const seq_bytes = std.mem.toBytes(std.mem.nativeToBig(u64, seq_num));
            for (0..8) |i| {
                nonce[4 + i] ^= seq_bytes[i];
            }
            return nonce;
        }
    };
}

pub const RecordError = error{
    BufferTooSmall,
    InvalidKeyLength,
    InvalidIvLength,
    UnsupportedCipherSuite,
    RecordTooLarge,
    DecryptionFailed,
    BadRecordMac,
    UnexpectedRecord,
};

/// TLS Record Layer — reads/writes TLS records over a `Conn`.
///
/// `Conn` must satisfy the `net.conn.from` contract (`read`/`write`/`close`).
pub fn RecordLayer(comptime Conn: type, comptime Crypto: type) type {
    comptime {
        _ = crypto_suite.is(Crypto);
    }
    return struct {
        conn: *Conn,
        read_cipher: CipherState(Crypto),
        write_cipher: CipherState(Crypto),
        read_seq: u64,
        write_seq: u64,
        version: ProtocolVersion,

        const Self = @This();

        pub fn init(conn: *Conn) Self {
            return .{
                .conn = conn,
                .read_cipher = .none,
                .write_cipher = .none,
                .read_seq = 0,
                .write_seq = 0,
                .version = .tls_1_2,
            };
        }

        pub fn setReadCipher(self: *Self, cipher: CipherState(Crypto)) void {
            self.read_cipher = cipher;
            self.read_seq = 0;
        }

        pub fn setWriteCipher(self: *Self, cipher: CipherState(Crypto)) void {
            self.write_cipher = cipher;
            self.write_seq = 0;
        }

        fn connWrite(self: *Self, data: []const u8) !void {
            var written: usize = 0;
            while (written < data.len) {
                const n = self.conn.write(data[written..]) catch return error.UnexpectedRecord;
                if (n == 0) return error.UnexpectedRecord;
                written += n;
            }
        }

        fn connRead(self: *Self, buf: []u8) !usize {
            return self.conn.read(buf) catch return error.UnexpectedRecord;
        }

        pub fn writeRecord(self: *Self, content_type: ContentType, plaintext: []const u8, buffer: []u8) !usize {
            if (plaintext.len > common.MAX_PLAINTEXT_LEN) {
                return error.RecordTooLarge;
            }

            switch (self.write_cipher) {
                .none => {
                    const total_len = RecordHeader.SIZE + plaintext.len;
                    if (buffer.len < total_len) return error.BufferTooSmall;

                    const header = RecordHeader{
                        .content_type = content_type,
                        .legacy_version = self.version,
                        .length = @intCast(plaintext.len),
                    };
                    try header.serialize(buffer[0..RecordHeader.SIZE]);
                    @memcpy(buffer[RecordHeader.SIZE..][0..plaintext.len], plaintext);

                    try self.connWrite(buffer[0..total_len]);
                    return total_len;
                },
                inline .aes_128_gcm, .aes_256_gcm, .chacha20_poly1305 => |*cipher| {
                    if (self.version == .tls_1_3) {
                        const inner_len = plaintext.len + 1;
                        const ciphertext_len = inner_len + 16;
                        const total_len = RecordHeader.SIZE + ciphertext_len;

                        if (buffer.len < total_len) return error.BufferTooSmall;

                        const header = RecordHeader{
                            .content_type = .application_data,
                            .legacy_version = .tls_1_2,
                            .length = @intCast(ciphertext_len),
                        };
                        try header.serialize(buffer[0..RecordHeader.SIZE]);

                        var inner_plaintext: [common.MAX_PLAINTEXT_LEN + 1]u8 = undefined;
                        @memcpy(inner_plaintext[0..plaintext.len], plaintext);
                        inner_plaintext[plaintext.len] = @intFromEnum(content_type);

                        const ad = buffer[0..RecordHeader.SIZE];

                        var tag: [16]u8 = undefined;
                        cipher.encrypt(
                            buffer[RecordHeader.SIZE..][0..inner_len],
                            &tag,
                            inner_plaintext[0..inner_len],
                            ad,
                            self.write_seq,
                        );
                        @memcpy(buffer[RecordHeader.SIZE + inner_len ..][0..16], &tag);

                        self.write_seq += 1;
                        try self.connWrite(buffer[0..total_len]);
                        return total_len;
                    } else {
                        const explicit_nonce_len: usize = 8;
                        const record_len = explicit_nonce_len + plaintext.len + 16;
                        const total_len = RecordHeader.SIZE + record_len;

                        if (buffer.len < total_len) return error.BufferTooSmall;

                        const header = RecordHeader{
                            .content_type = content_type,
                            .legacy_version = self.version,
                            .length = @intCast(record_len),
                        };
                        try header.serialize(buffer[0..RecordHeader.SIZE]);

                        var explicit_nonce: [8]u8 = undefined;
                        std.mem.writeInt(u64, &explicit_nonce, self.write_seq, .big);
                        @memcpy(buffer[RecordHeader.SIZE..][0..8], &explicit_nonce);

                        var ad: [13]u8 = undefined;
                        std.mem.writeInt(u64, ad[0..8], self.write_seq, .big);
                        ad[8] = @intFromEnum(content_type);
                        std.mem.writeInt(u16, ad[9..11], @intFromEnum(self.version), .big);
                        std.mem.writeInt(u16, ad[11..13], @intCast(plaintext.len), .big);

                        var tag: [16]u8 = undefined;
                        cipher.encryptTls12(
                            buffer[RecordHeader.SIZE + 8 ..][0..plaintext.len],
                            &tag,
                            plaintext,
                            &ad,
                            &explicit_nonce,
                        );
                        @memcpy(buffer[RecordHeader.SIZE + 8 + plaintext.len ..][0..16], &tag);

                        self.write_seq += 1;
                        try self.connWrite(buffer[0..total_len]);
                        return total_len;
                    }
                },
            }
        }

        pub fn readRecord(self: *Self, buffer: []u8, plaintext_out: []u8) !struct { content_type: ContentType, length: usize } {
            var header_buf: [RecordHeader.SIZE]u8 = undefined;
            var bytes_read: usize = 0;
            while (bytes_read < RecordHeader.SIZE) {
                const n = try self.connRead(header_buf[bytes_read..]);
                if (n == 0) return error.UnexpectedRecord;
                bytes_read += n;
            }

            const header = try RecordHeader.parse(&header_buf);
            if (header.length > common.MAX_CIPHERTEXT_LEN) {
                return error.RecordTooLarge;
            }

            if (buffer.len < header.length) return error.BufferTooSmall;
            bytes_read = 0;
            while (bytes_read < header.length) {
                const n = try self.connRead(buffer[bytes_read..header.length]);
                if (n == 0) return error.UnexpectedRecord;
                bytes_read += n;
            }

            const record_body = buffer[0..header.length];

            if (header.content_type == .change_cipher_spec) {
                if (plaintext_out.len < header.length) return error.BufferTooSmall;
                @memcpy(plaintext_out[0..header.length], record_body);
                return .{ .content_type = header.content_type, .length = header.length };
            }

            switch (self.read_cipher) {
                .none => {
                    if (plaintext_out.len < header.length) return error.BufferTooSmall;
                    @memcpy(plaintext_out[0..header.length], record_body);
                    return .{ .content_type = header.content_type, .length = header.length };
                },
                inline .aes_128_gcm, .aes_256_gcm, .chacha20_poly1305 => |*cipher| {
                    if (self.version == .tls_1_3) {
                        if (header.length < 17) return error.BadRecordMac;

                        const ciphertext_len = header.length - 16;
                        const ciphertext = record_body[0..ciphertext_len];
                        const tag = record_body[ciphertext_len..][0..16].*;

                        if (plaintext_out.len < ciphertext_len) return error.BufferTooSmall;

                        cipher.decrypt(
                            plaintext_out[0..ciphertext_len],
                            ciphertext,
                            tag,
                            &header_buf,
                            self.read_seq,
                        ) catch return error.BadRecordMac;

                        self.read_seq += 1;

                        var inner_len = ciphertext_len;
                        while (inner_len > 0 and plaintext_out[inner_len - 1] == 0) {
                            inner_len -= 1;
                        }
                        if (inner_len == 0) return error.DecryptionFailed;

                        inner_len -= 1;
                        const inner_content_type: ContentType = @enumFromInt(plaintext_out[inner_len]);

                        return .{ .content_type = inner_content_type, .length = inner_len };
                    } else {
                        if (header.length < 8 + 16 + 1) return error.BadRecordMac;

                        const explicit_nonce = record_body[0..8];
                        const ciphertext_len = header.length - 8 - 16;
                        const ciphertext = record_body[8..][0..ciphertext_len];
                        const tag = record_body[8 + ciphertext_len ..][0..16].*;

                        if (plaintext_out.len < ciphertext_len) return error.BufferTooSmall;

                        var ad: [13]u8 = undefined;
                        std.mem.writeInt(u64, ad[0..8], self.read_seq, .big);
                        ad[8] = @intFromEnum(header.content_type);
                        std.mem.writeInt(u16, ad[9..11], @intFromEnum(header.legacy_version), .big);
                        std.mem.writeInt(u16, ad[11..13], @intCast(ciphertext_len), .big);

                        cipher.decryptTls12(
                            plaintext_out[0..ciphertext_len],
                            ciphertext,
                            tag,
                            &ad,
                            explicit_nonce,
                        ) catch return error.BadRecordMac;

                        self.read_seq += 1;

                        return .{ .content_type = header.content_type, .length = ciphertext_len };
                    }
                },
            }
        }

        pub fn sendAlert(self: *Self, level: AlertLevel, description: AlertDescription, buffer: []u8) !void {
            const alert_data = [_]u8{
                @intFromEnum(level),
                @intFromEnum(description),
            };
            _ = try self.writeRecord(.alert, &alert_data, buffer);
        }
    };
}

pub const MockConn = struct {
    write_buf: [16384]u8 = undefined,
    write_len: usize = 0,
    read_buf: [16384]u8 = undefined,
    read_len: usize = 0,
    read_pos: usize = 0,
    closed: bool = false,

    const conn_mod = @import("../conn.zig");

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
