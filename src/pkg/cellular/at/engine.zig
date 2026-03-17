//! AT command engine: sendRaw, send(Cmd), pumpUrcs. Uses Io and Time (comptime-injected).
//! See plan.md §5.4+ and R40 (buf_size). Full implementation in Step 4.

const io = @import("../io/io.zig");
const parse = @import("parse.zig");
const commands = @import("commands.zig");

/// AT engine: Time and buf_size are comptime parameters; Io is provided at init.
pub fn AtEngine(comptime Time: type, comptime buf_size: usize) type {
    comptime {
        _ = Time;
    }
    return struct {
        io_instance: io.Io,
        rx_buf: [buf_size]u8 = [_]u8{0} ** buf_size,
        rx_len: usize = 0,

        const Self = @This();

        /// Build an engine that uses the given Io. Caller keeps ownership of the Io.
        pub fn init(io_instance: io.Io) Self {
            return .{ .io_instance = io_instance };
        }

        /// Sends raw command bytes; response handling and timeout in Step 4.
        pub fn sendRaw(self: *Self, cmd: []const u8) !void {
            _ = self;
            _ = cmd;
        }

        /// Sends typed command Cmd and returns parsed Response. Implement in Step 4.
        pub fn send(self: *Self, comptime Cmd: type, cmd: anytype) !Cmd.Response {
            _ = self;
            _ = cmd;
            comptime _ = @sizeOf(Cmd.Response);
            return error.Timeout;
        }

        /// Drains and dispatches URCs from the rx buffer. Implement in Step 4.
        pub fn pumpUrcs(self: *Self) void {
            _ = self;
        }
    };
}
