//! Generic Io interface and HAL wrappers (fromUart / fromSpi).
//! Type-erased read/write/poll; platform implements this to talk to the modem.
//! See plan.md §5.2 and cellular_dev.html.

const std = @import("std");

/// Errors returned by Io.read() / Io.write().
pub const IoError = error{ WouldBlock, Timeout, Closed, IoError };

/// Result of poll(): which operations are available without blocking.
pub const PollFlags = packed struct {
    readable: bool = false,
    writable: bool = false,
    _padding: u6 = 0,
};

/// Type-erased transport: read (non-blocking), write, poll.
/// read() returns WouldBlock when no data is available; use poll(timeout_ms) to wait.
pub const Io = struct {
    ctx: *anyopaque,
    readFn: *const fn (*anyopaque, []u8) IoError!usize,
    writeFn: *const fn (*anyopaque, []const u8) IoError!usize,
    pollFn: *const fn (*anyopaque, i32) PollFlags,

    pub fn read(self: Io, buf: []u8) IoError!usize {
        return self.readFn(self.ctx, buf);
    }

    pub fn write(self: Io, buf: []const u8) IoError!usize {
        return self.writeFn(self.ctx, buf);
    }

    pub fn poll(self: Io, timeout_ms: i32) PollFlags {
        return self.pollFn(self.ctx, timeout_ms);
    }
};

// Placeholder: fromUart / fromSpi will wrap HAL drivers. Stub compiles; implement in Step 2.
fn _readStub(_: *anyopaque, buf: []u8) IoError!usize {
    _ = buf;
    return error.WouldBlock;
}
fn _writeStub(_: *anyopaque, buf: []const u8) IoError!usize {
    return buf.len;
}
fn _pollStub(_: *anyopaque, _: i32) PollFlags {
    return .{};
}

/// Wraps a UART HAL instance into Io. Implement in Step 2 with real HAL.
pub fn fromUart(comptime UartType: type, ptr: *UartType) Io {
    _ = ptr;
    comptime _ = @sizeOf(UartType);
    var dummy: u8 = 0;
    return .{
        .ctx = @ptrCast(&dummy),
        .readFn = _readStub,
        .writeFn = _writeStub,
        .pollFn = _pollStub,
    };
}

/// Wraps an SPI HAL instance into Io. Implement when SPI transport is added.
pub fn fromSpi(comptime SpiType: type, ptr: *SpiType) Io {
    _ = ptr;
    comptime _ = @sizeOf(SpiType);
    var dummy: u8 = 0;
    return .{
        .ctx = @ptrCast(&dummy),
        .readFn = _readStub,
        .writeFn = _writeStub,
        .pollFn = _pollStub,
    };
}
