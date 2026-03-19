//! MockIo: test-only Io backed by two linear buffers (tx_buf/tx_len, rx_buf/rx_len/rx_pos).
//! No RingBuffer, no onSend. See plan.md and cellular_dev.html §5 / Step 2.

const std = @import("std");
const io_mod = @import("io.zig");

/// Test double for Io. feed()/feedSequence() supply bytes for read(); sent()/drain() inspect write.
/// Implement full API in Step 2.
/// When max_read_per_call is set, each read() returns at most that many bytes (for staged tests).
pub const MockIo = struct {
    tx_buf: [4096]u8 = [_]u8{0} ** 4096,
    tx_len: usize = 0,
    rx_buf: [4096]u8 = [_]u8{0} ** 4096,
    rx_len: usize = 0,
    rx_pos: usize = 0,
    /// If non-null, readFn returns at most this many bytes per call.
    max_read_per_call: ?usize = null,

    /// Create a MockIo. Use .io() to get the Io interface.
    pub fn init() MockIo {
        return .{};
    }

    /// Returns the Io interface backed by this MockIo.
    pub fn io(self: *MockIo) io_mod.Io {
        return .{
            .ctx = @ptrCast(self),
            .readFn = readFn,
            .writeFn = writeFn,
            .pollFn = pollFn,
        };
    }

    fn readFn(ctx: *anyopaque, buf: []u8) io_mod.IoError!usize {
        const self: *MockIo = @ptrCast(@alignCast(ctx));
        if (self.rx_pos >= self.rx_len) return error.WouldBlock;
        var n = @min(buf.len, self.rx_len - self.rx_pos);
        if (self.max_read_per_call) |max_n| {
            n = @min(n, max_n);
        }
        @memcpy(buf[0..n], self.rx_buf[self.rx_pos..][0..n]);
        self.rx_pos += n;
        return n;
    }

    fn writeFn(ctx: *anyopaque, buf: []const u8) io_mod.IoError!usize {
        const self: *MockIo = @ptrCast(@alignCast(ctx));
        const n = @min(buf.len, self.tx_buf.len - self.tx_len);
        @memcpy(self.tx_buf[self.tx_len..][0..n], buf[0..n]);
        self.tx_len += n;
        return n;
    }

    fn pollFn(ctx: *anyopaque, _: i32) io_mod.PollFlags {
        const self: *MockIo = @ptrCast(@alignCast(ctx));
        return .{
            .readable = self.rx_pos < self.rx_len,
            .writable = true,
        };
    }

    /// Append bytes to the rx buffer for the next read().
    pub fn feed(self: *MockIo, data: []const u8) void {
        const n = @min(data.len, self.rx_buf.len - self.rx_len);
        @memcpy(self.rx_buf[self.rx_len..][0..n], data[0..n]);
        self.rx_len += n;
    }

    /// Convenience: feed multiple slices in order.
    pub fn feedSequence(self: *MockIo, slices: []const []const u8) void {
        for (slices) |s| self.feed(s);
    }

    /// Returns the bytes written so far (for assertions). Drain in Step 2 if needed.
    pub fn sent(self: *const MockIo) []const u8 {
        return self.tx_buf[0..self.tx_len];
    }

    /// Reset write buffer for next test.
    pub fn drain(self: *MockIo) void {
        self.tx_len = 0;
    }

    /// UART contract for fromUart(MockIo, self): read from rx buffer.
    pub fn read(self: *MockIo, buf: []u8) io_mod.IoError!usize {
        if (self.rx_pos >= self.rx_len) return error.WouldBlock;
        const n = @min(buf.len, self.rx_len - self.rx_pos);
        @memcpy(buf[0..n], self.rx_buf[self.rx_pos..][0..n]);
        self.rx_pos += n;
        return n;
    }

    /// UART contract for fromUart(MockIo, self): write to tx buffer.
    pub fn write(self: *MockIo, buf: []const u8) io_mod.IoError!usize {
        const n = @min(buf.len, self.tx_buf.len - self.tx_len);
        @memcpy(self.tx_buf[self.tx_len..][0..n], buf[0..n]);
        self.tx_len += n;
        return n;
    }

    /// UART contract for fromUart(MockIo, self): poll flags (timeout_ms ignored in mock).
    pub fn poll(self: *MockIo, _: i32) io_mod.PollFlags {
        return .{
            .readable = self.rx_pos < self.rx_len,
            .writable = true,
        };
    }
};
