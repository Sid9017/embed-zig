const std = @import("std");
const crypto_suite = @import("../../../runtime/crypto/suite.zig");
const mutex_contract = @import("../../../runtime/sync/mutex.zig");
const rng_contract = @import("../../../runtime/rng.zig");
pub const conn_mod = @import("../conn.zig");
pub const client_mod = @import("client.zig");
pub const common = @import("common.zig");

pub const Options = struct {
    skip_cert_verify: bool = false,
    timeout_ms: u32 = 30000,
};

/// TLS Stream — wraps a plain `Conn` into an encrypted stream that itself
/// satisfies the `net.conn.from` contract (`read`, `write`, `close`).
///
/// This is the primary high-level API: create a `Stream`, call `handshake`,
/// then use `read`/`write`/`close` like any other `Conn`.
pub fn Stream(comptime Conn: type, comptime Crypto: type, comptime Rng: type, comptime Mutex: type) type {
    comptime {
        _ = conn_mod.from(Conn);
        _ = crypto_suite.is(Crypto);
        _ = mutex_contract.is(Mutex);
        _ = rng_contract.is(Rng);
    }

    return struct {
        client: ?client_mod.Client(Conn, Crypto, Rng, Mutex),
        conn: *Conn,
        allocator: std.mem.Allocator,
        hostname: []const u8,
        options: Options,

        const Self = @This();

        pub fn init(conn: *Conn, allocator: std.mem.Allocator, hostname: []const u8, options: Options) !Self {
            return .{
                .client = null,
                .conn = conn,
                .allocator = allocator,
                .hostname = hostname,
                .options = options,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.client) |*c| {
                c.deinit();
                self.client = null;
            }
        }

        /// Perform TLS handshake, upgrading the underlying Conn.
        pub fn handshake(self: *Self) !void {
            self.client = try client_mod.Client(Conn, Crypto, Rng, Mutex).init(self.conn, .{
                .allocator = self.allocator,
                .hostname = self.hostname,
                .skip_verify = self.options.skip_cert_verify,
                .timeout_ms = self.options.timeout_ms,
            });
            errdefer {
                if (self.client) |*c| c.deinit();
                self.client = null;
            }

            try self.client.?.connect();
        }

        /// Satisfies `net.conn.from` — read decrypted data.
        pub fn read(self: *Self, buffer: []u8) conn_mod.Error!usize {
            if (self.client) |*c| {
                return c.recv(buffer) catch return conn_mod.Error.ReadFailed;
            }
            return conn_mod.Error.Closed;
        }

        /// Satisfies `net.conn.from` — write data (encrypted on the wire).
        pub fn write(self: *Self, data: []const u8) conn_mod.Error!usize {
            if (self.client) |*c| {
                return c.send(data) catch return conn_mod.Error.WriteFailed;
            }
            return conn_mod.Error.Closed;
        }

        /// Satisfies `net.conn.from` — send close_notify and close.
        pub fn close(self: *Self) void {
            if (self.client) |*c| {
                c.close() catch {};
            }
        }
    };
}

pub const TestMockConn = struct {
    const Self = @This();
    closed: bool = false,

    pub fn read(_: *Self, _: []u8) conn_mod.Error!usize {
        return conn_mod.Error.ReadFailed;
    }
    pub fn write(_: *Self, _: []const u8) conn_mod.Error!usize {
        return conn_mod.Error.WriteFailed;
    }
    pub fn close(self: *Self) void {
        self.closed = true;
    }
};
