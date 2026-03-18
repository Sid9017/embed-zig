const std = @import("std");
const embed = @import("../../../mod.zig");
const runtime_suite = embed.runtime;
const conn_mod = embed.pkg.net.conn;
const client_mod = @import("client.zig");
const common = @import("common.zig");

pub const Options = struct {
    skip_cert_verify: bool = false,
    timeout_ms: u32 = 30000,
};

/// TLS Stream — wraps a plain `Conn` into an encrypted stream that itself
/// satisfies the `net.conn.from` contract (`read`, `write`, `close`).
///
/// This is the primary high-level API: create a `Stream`, call `handshake`,
/// then use `read`/`write`/`close` like any other `Conn`.
///
/// Type parameters:
///   - `Conn`:    underlying transport (must satisfy `net.conn` contract)
///   - `Runtime`: sealed runtime suite (must satisfy `runtime.suite.is`)
pub fn Stream(comptime Conn: type, comptime Runtime: type) type {
    comptime {
        _ = conn_mod.from(Conn);
        _ = runtime_suite.is(Runtime);
    }

    return struct {
        client: ?client_mod.Client(Conn, Runtime),
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
            self.client = try client_mod.Client(Conn, Runtime).init(self.conn, .{
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
