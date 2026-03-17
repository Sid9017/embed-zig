//! GSM 07.10 CMUX framing: multiplex AT and PPP over a single serial link.
//! Full implementation in Step 9. See plan.md §5.6 and R41.

const io = @import("../io/io.zig");
const types = @import("../types.zig");

/// CMUX frame types (SABM, UA, DM, UI, etc.). Expand per GSM 07.10 in Step 9.
pub const FrameType = enum(u8) {
    sabm = 0x2f,
    ua = 0x63,
    dm = 0x0f,
    ui = 0x03,
    _,
};

// Stub I/O used when openChannel is not yet implemented.
fn _stubRead(_: *anyopaque, _: []u8) io.IoError!usize {
    return error.WouldBlock;
}
fn _stubWrite(_: *anyopaque, buf: []const u8) io.IoError!usize {
    return buf.len;
}
fn _stubPoll(_: *anyopaque, _: i32) io.PollFlags {
    return .{};
}

/// Stub: CMUX session managing DLCIs and pump thread. Implement in Step 9.
pub fn CmuxSession(comptime IoType: type, comptime Notify: type) type {
    return struct {
        io: IoType,
        notify: Notify,
        dummy_ctx: u8 = 0,

        pub fn init(io_instance: IoType, notify_instance: Notify) @This() {
            return .{
                .io = io_instance,
                .notify = notify_instance,
            };
        }

        /// Returns a placeholder Io until real channel Io is implemented in Step 9.
        pub fn openChannel(self: *@This(), dlci: u8, role: types.CmuxChannelRole) !io.Io {
            _ = dlci;
            _ = role;
            return .{
                .ctx = @ptrCast(&self.dummy_ctx),
                .readFn = _stubRead,
                .writeFn = _stubWrite,
                .pollFn = _stubPoll,
            };
        }

        pub fn startPump(self: *@This()) !void {
            _ = self;
        }

        pub fn stopPump(self: *@This()) void {
            _ = self;
        }
    };
}
