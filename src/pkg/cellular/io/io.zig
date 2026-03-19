//! Generic Io interface and HAL wrappers (fromUart / fromUSB).
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

/// UART-like contract for fromUart: read(*self, buf), write(*self, buf), poll(*self, timeout_ms).
/// Platform adapters (or MockIo in tests) must provide these; IoError and PollFlags are from this module.
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

/// Wraps a UART-like instance into Io. UartType must have:
/// - read(self: *UartType, buf: []u8) IoError!usize
/// - write(self: *UartType, buf: []const u8) IoError!usize
/// - poll(self: *UartType, timeout_ms: i32) PollFlags
pub fn fromUart(comptime UartType: type, ptr: *UartType) Io {
    comptime {
        _ = @as(*const fn (*UartType, []u8) IoError!usize, &UartType.read);
        _ = @as(*const fn (*UartType, []const u8) IoError!usize, &UartType.write);
        _ = @as(*const fn (*UartType, i32) PollFlags, &UartType.poll);
    }
    const Wrap = struct {
        fn read(ctx: *anyopaque, buf: []u8) IoError!usize {
            const p: *UartType = @ptrCast(@alignCast(ctx));
            return p.read(buf);
        }
        fn write(ctx: *anyopaque, buf: []const u8) IoError!usize {
            const p: *UartType = @ptrCast(@alignCast(ctx));
            return p.write(buf);
        }
        fn poll(ctx: *anyopaque, timeout_ms: i32) PollFlags {
            const p: *UartType = @ptrCast(@alignCast(ctx));
            return p.poll(timeout_ms);
        }
    };
    return .{
        .ctx = @ptrCast(ptr),
        .readFn = Wrap.read,
        .writeFn = Wrap.write,
        .pollFn = Wrap.poll,
    };
}

/// Wraps a USB (e.g. CDC-ACM) transport into Io. Same contract as fromUart: read/write/poll.
/// Stub until USB transport is implemented; implement when USB HAL adapter is added.
pub fn fromUSB(comptime UsbType: type, ptr: *UsbType) Io {
    _ = ptr;
    comptime _ = @sizeOf(UsbType);
    var dummy: u8 = 0;
    return .{
        .ctx = @ptrCast(&dummy),
        .readFn = _readStub,
        .writeFn = _writeStub,
        .pollFn = _pollStub,
    };
}
