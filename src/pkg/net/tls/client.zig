const std = @import("std");
const embed = @import("../../../mod.zig");
const runtime_suite = embed.runtime;
const conn_mod = embed.pkg.net.conn;
const common = @import("common.zig");
const record = @import("record.zig");
const handshake = @import("handshake.zig");

const ProtocolVersion = common.ProtocolVersion;
const CipherSuite = common.CipherSuite;
const AlertDescription = common.AlertDescription;

pub const Config = struct {
    allocator: std.mem.Allocator,
    hostname: []const u8 = "",
    skip_verify: bool = false,
    alpn_protocols: []const []const u8 = &.{},
    min_version: ProtocolVersion = .tls_1_2,
    max_version: ProtocolVersion = .tls_1_3,
    timeout_ms: u32 = 30000,
};

/// TLS Client — upgrades a plain `Conn` into a secure channel.
///
/// Thread-safe: `send` and `recv` can be called concurrently.
///
/// Type parameters:
///   - `Conn`:    underlying transport (must satisfy `net.conn` contract)
///   - `Runtime`: sealed runtime suite (must satisfy `runtime.suite.is`)
pub fn Client(comptime Conn: type, comptime Runtime: type) type {
    comptime {
        _ = conn_mod.from(Conn);
        _ = runtime_suite.is(Runtime);
    }

    return struct {
        config: Config,
        conn: *Conn,
        hs: handshake.ClientHandshake(Conn, Runtime),
        connected: bool,
        received_close_notify: bool,

        write_mutex: Runtime.Mutex,
        read_mutex: Runtime.Mutex,

        read_buffer: []u8,
        write_buffer: []u8,

        pending_plaintext: [common.MAX_CIPHERTEXT_LEN]u8 = undefined,
        pending_pos: usize = 0,
        pending_len: usize = 0,

        const Self = @This();

        pub const crypto = Runtime.Crypto;

        pub fn init(conn: *Conn, config: Config) !Self {
            const read_buffer = try config.allocator.alloc(u8, common.MAX_CIPHERTEXT_LEN + 256);
            errdefer config.allocator.free(read_buffer);

            const write_buffer = try config.allocator.alloc(u8, common.MAX_CIPHERTEXT_LEN + 256);
            errdefer config.allocator.free(write_buffer);

            return Self{
                .config = config,
                .conn = conn,
                .hs = try handshake.ClientHandshake(Conn, Runtime).init(
                    conn,
                    config.hostname,
                    config.allocator,
                    config.skip_verify,
                    Runtime.Rng.init(),
                ),
                .connected = false,
                .received_close_notify = false,
                .write_mutex = Runtime.Mutex.init(),
                .read_mutex = Runtime.Mutex.init(),
                .read_buffer = read_buffer,
                .write_buffer = write_buffer,
            };
        }

        pub fn deinit(self: *Self) void {
            self.read_mutex.deinit();
            self.write_mutex.deinit();
            self.config.allocator.free(self.read_buffer);
            self.config.allocator.free(self.write_buffer);
        }

        pub fn connect(self: *Self) !void {
            try self.hs.handshake(self.write_buffer);
            self.connected = true;
        }

        pub fn send(self: *Self, data: []const u8) !usize {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();

            if (!@atomicLoad(bool, &self.connected, .acquire)) return error.NotConnected;
            if (@atomicLoad(bool, &self.received_close_notify, .acquire)) return error.ConnectionClosed;

            var sent: usize = 0;
            while (sent < data.len) {
                const chunk_size = @min(data.len - sent, common.MAX_PLAINTEXT_LEN);
                _ = try self.hs.records.writeRecord(
                    .application_data,
                    data[sent..][0..chunk_size],
                    self.write_buffer,
                );
                sent += chunk_size;
            }
            return sent;
        }

        pub fn recv(self: *Self, buffer: []u8) !usize {
            self.read_mutex.lock();
            defer self.read_mutex.unlock();

            if (!@atomicLoad(bool, &self.connected, .acquire)) return error.NotConnected;
            if (@atomicLoad(bool, &self.received_close_notify, .acquire)) return 0;

            if (self.pending_len > 0) {
                const n = @min(self.pending_len, buffer.len);
                @memcpy(buffer[0..n], self.pending_plaintext[self.pending_pos..][0..n]);
                self.pending_pos += n;
                self.pending_len -= n;
                return n;
            }

            while (true) {
                var plaintext: [common.MAX_CIPHERTEXT_LEN]u8 = undefined;
                const result = try self.hs.records.readRecord(self.read_buffer, &plaintext);

                switch (result.content_type) {
                    .application_data => {
                        const copy_len = @min(result.length, buffer.len);
                        @memcpy(buffer[0..copy_len], plaintext[0..copy_len]);

                        if (result.length > copy_len) {
                            const leftover = result.length - copy_len;
                            @memcpy(self.pending_plaintext[0..leftover], plaintext[copy_len..result.length]);
                            self.pending_pos = 0;
                            self.pending_len = leftover;
                        }

                        return copy_len;
                    },
                    .alert => {
                        if (result.length >= 2) {
                            if (std.meta.intToEnum(AlertDescription, plaintext[1])) |desc| {
                                if (desc == .close_notify) {
                                    @atomicStore(bool, &self.received_close_notify, true, .release);
                                    return 0;
                                }
                            } else |_| {}
                        }
                        return error.AlertReceived;
                    },
                    .handshake => {
                        continue;
                    },
                    else => return error.UnexpectedMessage,
                }
            }
        }

        pub fn close(self: *Self) !void {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();

            if (@atomicLoad(bool, &self.connected, .acquire) and !@atomicLoad(bool, &self.received_close_notify, .acquire)) {
                try self.hs.records.sendAlert(
                    .warning,
                    .close_notify,
                    self.write_buffer,
                );
            }
            @atomicStore(bool, &self.connected, false, .release);
        }

        pub fn getVersion(self: *Self) ProtocolVersion {
            return self.hs.version;
        }

        pub fn getCipherSuite(self: *Self) CipherSuite {
            return self.hs.cipher_suite;
        }

        pub fn isConnected(self: *Self) bool {
            return @atomicLoad(bool, &self.connected, .acquire) and
                !@atomicLoad(bool, &self.received_close_notify, .acquire);
        }
    };
}

pub const Error = error{
    NotConnected,
    ConnectionClosed,
    AlertReceived,
    UnexpectedMessage,
    HandshakeFailed,
    OutOfMemory,
    BufferTooSmall,
    InvalidHandshake,
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

pub fn connect(
    comptime Conn: type,
    comptime Runtime: type,
    conn: *Conn,
    hostname: []const u8,
    allocator: std.mem.Allocator,
) !Client(Conn, Runtime) {
    comptime {
        _ = conn_mod.from(Conn);
        _ = runtime_suite.is(Runtime);
    }
    var tls_client = try Client(Conn, Runtime).init(conn, .{
        .allocator = allocator,
        .hostname = hostname,
    });
    errdefer tls_client.deinit();

    try tls_client.connect();
    return tls_client;
}
