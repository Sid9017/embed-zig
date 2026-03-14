//! Abstract bidirectional byte stream (like Go's net.Conn / io.ReadWriteCloser).
//!
//! Any type satisfying this contract can be used as a transport for TLS,
//! HTTP, or other protocol layers — regardless of whether the underlying
//! transport is a TCP socket, a serial port, a memory pipe, etc.

const runtime = struct {
    pub const socket = @import("../../runtime/socket.zig");
    pub const std = @import("../../runtime/std.zig");
};

/// Conn contract error set.
pub const Error = error{
    ReadFailed,
    WriteFailed,
    Closed,
    Timeout,
};

/// Validate that `Impl` satisfies the Conn contract.
///
/// Required methods:
///   - `read(*Impl, []u8) Error!usize`
///   - `write(*Impl, []const u8) Error!usize`
///   - `close(*Impl) void`
pub fn from(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn (*Impl, []u8) Error!usize, &Impl.read);
        _ = @as(*const fn (*Impl, []const u8) Error!usize, &Impl.write);
        _ = @as(*const fn (*Impl) void, &Impl.close);
    }
    return Impl;
}

/// Adapt a `runtime.socket`-conforming type into a `net.Conn`.
///
/// Maps `send`/`recv`/`close` → `write`/`read`/`close` with error translation.
/// The resulting type satisfies `from()` and can be used with TLS, HTTP, etc.
pub fn SocketConn(comptime Socket: type) type {
    return struct {
        socket: *Socket,

        const Self = @This();

        pub fn init(socket: *Socket) Self {
            return .{ .socket = socket };
        }

        pub fn read(self: *Self, buf: []u8) Error!usize {
            return self.socket.recv(buf) catch |e| switch (e) {
                error.Timeout => Error.Timeout,
                error.Closed => Error.Closed,
                else => Error.ReadFailed,
            };
        }

        pub fn write(self: *Self, data: []const u8) Error!usize {
            return self.socket.send(data) catch |e| switch (e) {
                error.Timeout => Error.Timeout,
                error.Closed => Error.Closed,
                else => Error.WriteFailed,
            };
        }

        pub fn close(self: *Self) void {
            self.socket.close();
        }

        comptime {
            _ = from(Self);
        }
    };
}
