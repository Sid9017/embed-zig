//! Unit tests for `pkg/cellular/at/engine.zig`.
//! Uses MockIo, `FakeTime`, and local Io stubs (`ChunkRead`, failing write/read, etc.).

const std = @import("std");
const embed = @import("embed");
const engine = embed.pkg.cellular.at.engine;
const commands = embed.pkg.cellular.at.commands;
const mock_mod = embed.pkg.cellular.io.mock;
const io_mod = embed.pkg.cellular.io.io_mod;

const FakeTime = struct {
    ms: *u64,
    pub fn nowMs(self: FakeTime) u64 {
        return self.ms.*;
    }
    pub fn sleepMs(self: FakeTime, delta: u32) void {
        self.ms.* +%= delta;
    }
};

fn EngineSmall() type {
    return engine.AtEngine(FakeTime, 32);
}

fn Engine512() type {
    return engine.AtEngine(FakeTime, 512);
}

// --- Io stubs (beyond MockIo) for error and chunking paths ---

/// Caps each `read` to `max_read` bytes so the engine must loop.
const ChunkRead = struct {
    mock: *mock_mod.MockIo,
    max_read: usize,
    pub fn io(self: *ChunkRead) io_mod.Io {
        return .{
            .ctx = @ptrCast(self),
            .readFn = readFn,
            .writeFn = writeFn,
            .pollFn = pollFn,
        };
    }
    fn readFn(ctx: *anyopaque, buf: []u8) io_mod.IoError!usize {
        const s: *ChunkRead = @ptrCast(@alignCast(ctx));
        if (buf.len == 0) return 0;
        const lim = @min(buf.len, s.max_read);
        return s.mock.read(buf[0..lim]);
    }
    fn writeFn(ctx: *anyopaque, buf: []const u8) io_mod.IoError!usize {
        const s: *ChunkRead = @ptrCast(@alignCast(ctx));
        return s.mock.write(buf);
    }
    fn pollFn(ctx: *anyopaque, ms: i32) io_mod.PollFlags {
        const s: *ChunkRead = @ptrCast(@alignCast(ctx));
        return s.mock.poll(ms);
    }
};

/// Caps each `write` to `max_write` bytes so the engine must loop `sendRaw` write phase.
const ChunkWrite = struct {
    mock: *mock_mod.MockIo,
    max_write: usize,
    pub fn io(self: *ChunkWrite) io_mod.Io {
        return .{
            .ctx = @ptrCast(self),
            .readFn = readFn,
            .writeFn = writeFn,
            .pollFn = pollFn,
        };
    }
    fn readFn(ctx: *anyopaque, buf: []u8) io_mod.IoError!usize {
        const s: *ChunkWrite = @ptrCast(@alignCast(ctx));
        return s.mock.read(buf);
    }
    fn writeFn(ctx: *anyopaque, buf: []const u8) io_mod.IoError!usize {
        const s: *ChunkWrite = @ptrCast(@alignCast(ctx));
        const n = @min(buf.len, s.max_write);
        return s.mock.write(buf[0..n]);
    }
    fn pollFn(ctx: *anyopaque, ms: i32) io_mod.PollFlags {
        const s: *ChunkWrite = @ptrCast(@alignCast(ctx));
        return s.mock.poll(ms);
    }
};

const WriteAlwaysFails = struct {
    mock: *mock_mod.MockIo,
    pub fn io(self: *WriteAlwaysFails) io_mod.Io {
        return .{
            .ctx = @ptrCast(self),
            .readFn = readFn,
            .writeFn = writeFn,
            .pollFn = pollFn,
        };
    }
    fn readFn(ctx: *anyopaque, buf: []u8) io_mod.IoError!usize {
        const s: *WriteAlwaysFails = @ptrCast(@alignCast(ctx));
        return s.mock.read(buf);
    }
    fn writeFn(_: *anyopaque, _: []const u8) io_mod.IoError!usize {
        return error.IoError;
    }
    fn pollFn(ctx: *anyopaque, ms: i32) io_mod.PollFlags {
        const s: *WriteAlwaysFails = @ptrCast(@alignCast(ctx));
        return s.mock.poll(ms);
    }
};

const WriteReturnsZero = struct {
    mock: *mock_mod.MockIo,
    pub fn io(self: *WriteReturnsZero) io_mod.Io {
        return .{
            .ctx = @ptrCast(self),
            .readFn = readFn,
            .writeFn = writeFn,
            .pollFn = pollFn,
        };
    }
    fn readFn(ctx: *anyopaque, buf: []u8) io_mod.IoError!usize {
        const s: *WriteReturnsZero = @ptrCast(@alignCast(ctx));
        return s.mock.read(buf);
    }
    fn writeFn(_: *anyopaque, _: []const u8) io_mod.IoError!usize {
        return 0;
    }
    fn pollFn(ctx: *anyopaque, ms: i32) io_mod.PollFlags {
        const s: *WriteReturnsZero = @ptrCast(@alignCast(ctx));
        return s.mock.poll(ms);
    }
};

/// After `ok_reads` successful mock reads, further reads return `err`.
const ReadFailsAfter = struct {
    mock: *mock_mod.MockIo,
    ok_reads: usize,
    count: usize = 0,
    err: io_mod.IoError,
    pub fn io(self: *ReadFailsAfter) io_mod.Io {
        return .{
            .ctx = @ptrCast(self),
            .readFn = readFn,
            .writeFn = writeFn,
            .pollFn = pollFn,
        };
    }
    fn readFn(ctx: *anyopaque, buf: []u8) io_mod.IoError!usize {
        const s: *ReadFailsAfter = @ptrCast(@alignCast(ctx));
        if (s.count < s.ok_reads) {
            s.count += 1;
            return s.mock.read(buf);
        }
        return s.err;
    }
    fn writeFn(ctx: *anyopaque, buf: []const u8) io_mod.IoError!usize {
        const s: *ReadFailsAfter = @ptrCast(@alignCast(ctx));
        return s.mock.write(buf);
    }
    fn pollFn(ctx: *anyopaque, ms: i32) io_mod.PollFlags {
        const s: *ReadFailsAfter = @ptrCast(@alignCast(ctx));
        return s.mock.poll(ms);
    }
};

/// Reads at most one byte per call; after `n_ok` successful reads, returns IoError (no terminal in feed).
const ReadOneByteThenFail = struct {
    mock: *mock_mod.MockIo,
    n_ok: usize,
    count: usize = 0,
    pub fn io(self: *ReadOneByteThenFail) io_mod.Io {
        return .{
            .ctx = @ptrCast(self),
            .readFn = readFn,
            .writeFn = writeFn,
            .pollFn = pollFn,
        };
    }
    fn readFn(ctx: *anyopaque, buf: []u8) io_mod.IoError!usize {
        const s: *ReadOneByteThenFail = @ptrCast(@alignCast(ctx));
        if (s.count >= s.n_ok) return error.IoError;
        s.count += 1;
        if (buf.len == 0) return 0;
        return s.mock.read(buf[0..1]);
    }
    fn writeFn(ctx: *anyopaque, buf: []const u8) io_mod.IoError!usize {
        const s: *ReadOneByteThenFail = @ptrCast(@alignCast(ctx));
        return s.mock.write(buf);
    }
    fn pollFn(ctx: *anyopaque, ms: i32) io_mod.PollFlags {
        const s: *ReadOneByteThenFail = @ptrCast(@alignCast(ctx));
        return s.mock.poll(ms);
    }
};

const PumpFirstReadZero = struct {
    mock: *mock_mod.MockIo,
    returned_zero: bool = false,
    pub fn io(self: *PumpFirstReadZero) io_mod.Io {
        return .{
            .ctx = @ptrCast(self),
            .readFn = readFn,
            .writeFn = writeFn,
            .pollFn = pollFn,
        };
    }
    fn readFn(ctx: *anyopaque, buf: []u8) io_mod.IoError!usize {
        const s: *PumpFirstReadZero = @ptrCast(@alignCast(ctx));
        if (!s.returned_zero) {
            s.returned_zero = true;
            return 0;
        }
        return s.mock.read(buf);
    }
    fn writeFn(ctx: *anyopaque, buf: []const u8) io_mod.IoError!usize {
        const s: *PumpFirstReadZero = @ptrCast(@alignCast(ctx));
        return s.mock.write(buf);
    }
    fn pollFn(ctx: *anyopaque, ms: i32) io_mod.PollFlags {
        const s: *PumpFirstReadZero = @ptrCast(@alignCast(ctx));
        return s.mock.poll(ms);
    }
};

/// One successful read then non-WouldBlock error (pumpUrcs `catch break`).
const PumpReadThenError = struct {
    mock: *mock_mod.MockIo,
    after_first: bool = false,
    pub fn io(self: *PumpReadThenError) io_mod.Io {
        return .{
            .ctx = @ptrCast(self),
            .readFn = readFn,
            .writeFn = writeFn,
            .pollFn = pollFn,
        };
    }
    fn readFn(ctx: *anyopaque, buf: []u8) io_mod.IoError!usize {
        const s: *PumpReadThenError = @ptrCast(@alignCast(ctx));
        if (!s.after_first) {
            s.after_first = true;
            return s.mock.read(buf);
        }
        return error.Closed;
    }
    fn writeFn(ctx: *anyopaque, buf: []const u8) io_mod.IoError!usize {
        const s: *PumpReadThenError = @ptrCast(@alignCast(ctx));
        return s.mock.write(buf);
    }
    fn pollFn(ctx: *anyopaque, ms: i32) io_mod.PollFlags {
        const s: *PumpReadThenError = @ptrCast(@alignCast(ctx));
        return s.mock.poll(ms);
    }
};

test "sendRaw ok writes command and returns ok on OK" {
    var m = mock_mod.MockIo.init();
    var clock: u64 = 0;
    var e = Engine512().init(m.io(), FakeTime{ .ms = &clock });
    m.feed("OK\r\n");
    const r = e.sendRaw("AT\r\n", 5000);
    try std.testing.expectEqual(engine.AtStatus.ok, r.status);
    try std.testing.expectEqualStrings("AT\r\n", m.sent());
}

test "sendRaw gen_error on bare ERROR" {
    var m = mock_mod.MockIo.init();
    var clock: u64 = 0;
    var e = Engine512().init(m.io(), FakeTime{ .ms = &clock });
    m.feed("ERROR\r\n");
    const r = e.sendRaw("AT\r\n", 5000);
    try std.testing.expectEqual(engine.AtStatus.gen_error, r.status);
}

test "sendRaw cme_error with code" {
    var m = mock_mod.MockIo.init();
    var clock: u64 = 0;
    var e = Engine512().init(m.io(), FakeTime{ .ms = &clock });
    m.feed("+CME ERROR: 10\r\n");
    const r = e.sendRaw("AT\r\n", 5000);
    try std.testing.expectEqual(engine.AtStatus.cme_error, r.status);
    try std.testing.expectEqual(@as(u16, 10), r.error_code.?);
}

test "sendRaw cms_error with code" {
    var m = mock_mod.MockIo.init();
    var clock: u64 = 0;
    var e = Engine512().init(m.io(), FakeTime{ .ms = &clock });
    m.feed("+CMS ERROR: 2\r\n");
    const r = e.sendRaw("AT\r\n", 5000);
    try std.testing.expectEqual(engine.AtStatus.cms_error, r.status);
    try std.testing.expectEqual(@as(u16, 2), r.error_code.?);
}

test "sendRaw timeout when no terminal" {
    var m = mock_mod.MockIo.init();
    var clock: u64 = 0;
    var e = Engine512().init(m.io(), FakeTime{ .ms = &clock });
    const r = e.sendRaw("AT\r\n", 20);
    try std.testing.expectEqual(engine.AtStatus.timeout, r.status);
    try std.testing.expect(clock >= 20);
}

test "sendRaw overflow when rx exceeds buf_size" {
    var m = mock_mod.MockIo.init();
    var clock: u64 = 0;
    var e = EngineSmall().init(m.io(), FakeTime{ .ms = &clock });
    var noise: [40]u8 = undefined;
    @memset(&noise, 'X');
    m.feed(&noise);
    const r = e.sendRaw("A\r\n", 5000);
    try std.testing.expectEqual(engine.AtStatus.overflow, r.status);
}

test "sendRaw io_error when write fails" {
    var m = mock_mod.MockIo.init();
    var stub: WriteAlwaysFails = .{ .mock = &m };
    var clock: u64 = 0;
    var e = Engine512().init(stub.io(), FakeTime{ .ms = &clock });
    const r = e.sendRaw("AT\r\n", 5000);
    try std.testing.expectEqual(engine.AtStatus.io_error, r.status);
    try std.testing.expectEqualStrings("", m.sent());
}

test "sendRaw io_error when write returns zero" {
    var m = mock_mod.MockIo.init();
    var stub: WriteReturnsZero = .{ .mock = &m };
    var clock: u64 = 0;
    var e = Engine512().init(stub.io(), FakeTime{ .ms = &clock });
    const r = e.sendRaw("AT\r\n", 5000);
    try std.testing.expectEqual(engine.AtStatus.io_error, r.status);
}

test "sendRaw io_error when read fails" {
    var m = mock_mod.MockIo.init();
    m.feed("OK\r\n");
    var stub: ReadFailsAfter = .{ .mock = &m, .ok_reads = 0, .err = error.IoError };
    var clock: u64 = 0;
    var e = Engine512().init(stub.io(), FakeTime{ .ms = &clock });
    const r = e.sendRaw("AT\r\n", 5000);
    try std.testing.expectEqual(engine.AtStatus.io_error, r.status);
}

test "sendRaw io_error after partial read without terminal" {
    var m = mock_mod.MockIo.init();
    m.feed("abcdefghij");
    var stub: ReadOneByteThenFail = .{ .mock = &m, .n_ok = 4 };
    var clock: u64 = 0;
    var e = Engine512().init(stub.io(), FakeTime{ .ms = &clock });
    const r = e.sendRaw("AT\r\n", 5000);
    try std.testing.expectEqual(engine.AtStatus.io_error, r.status);
    try std.testing.expectEqualStrings("abcd", r.body);
}

test "sendRaw completes OK across chunked reads" {
    var m = mock_mod.MockIo.init();
    m.feed("OK\r\n");
    var ch: ChunkRead = .{ .mock = &m, .max_read = 1 };
    var clock: u64 = 0;
    var e = Engine512().init(ch.io(), FakeTime{ .ms = &clock });
    const r = e.sendRaw("AT\r\n", 5000);
    try std.testing.expectEqual(engine.AtStatus.ok, r.status);
}

test "sendRaw completes OK across chunked writes" {
    var m = mock_mod.MockIo.init();
    m.feed("OK\r\n");
    var ch: ChunkWrite = .{ .mock = &m, .max_write = 1 };
    var clock: u64 = 0;
    var e = Engine512().init(ch.io(), FakeTime{ .ms = &clock });
    const r = e.sendRaw("AT\r\n", 5000);
    try std.testing.expectEqual(engine.AtStatus.ok, r.status);
    try std.testing.expectEqualStrings("AT\r\n", m.sent());
}

test "send Probe ok" {
    var m = mock_mod.MockIo.init();
    var clock: u64 = 0;
    var e = Engine512().init(m.io(), FakeTime{ .ms = &clock });
    m.feed("OK\r\n");
    const out = e.send(commands.Probe, {});
    try std.testing.expectEqual(engine.AtStatus.ok, out.status);
    try std.testing.expectEqualStrings("AT\r\n", m.sent());
}

test "send GetSignalQuality parses +CSQ on ok" {
    var m = mock_mod.MockIo.init();
    var clock: u64 = 0;
    var e = Engine512().init(m.io(), FakeTime{ .ms = &clock });
    m.feed("+CSQ: 20,0\r\n\r\nOK\r\n");
    const out = e.send(commands.GetSignalQuality, {});
    try std.testing.expectEqual(engine.AtStatus.ok, out.status);
    try std.testing.expect(out.value != null);
    try std.testing.expectEqual(@as(i8, -73), out.value.?.rssi);
    try std.testing.expectEqual(@as(u8, 0), out.value.?.ber.?);
}

test "send GetSignalQuality error leaves value null" {
    var m = mock_mod.MockIo.init();
    var clock: u64 = 0;
    var e = Engine512().init(m.io(), FakeTime{ .ms = &clock });
    m.feed("ERROR\r\n");
    const out = e.send(commands.GetSignalQuality, {});
    try std.testing.expectEqual(engine.AtStatus.gen_error, out.status);
    try std.testing.expect(out.value == null);
}

test "send GetSignalQuality ok without CSQ line yields null value" {
    var m = mock_mod.MockIo.init();
    var clock: u64 = 0;
    var e = Engine512().init(m.io(), FakeTime{ .ms = &clock });
    m.feed("OK\r\n");
    const out = e.send(commands.GetSignalQuality, {});
    try std.testing.expectEqual(engine.AtStatus.ok, out.status);
    try std.testing.expect(out.value == null);
}

test "send GetModuleInfo ok with body still null value until parse implemented" {
    var m = mock_mod.MockIo.init();
    var clock: u64 = 0;
    var e = Engine512().init(m.io(), FakeTime{ .ms = &clock });
    m.feed("Quectel\r\nOK\r\n");
    const out = e.send(commands.GetModuleInfo, {});
    try std.testing.expectEqual(engine.AtStatus.ok, out.status);
    try std.testing.expect(out.value == null);
}

test "AtResponse lineIterator yields trimmed lines" {
    var m = mock_mod.MockIo.init();
    var clock: u64 = 0;
    var e = Engine512().init(m.io(), FakeTime{ .ms = &clock });
    m.feed("echo\r\n+CSQ: 1,99\r\nOK\r\n");
    const r = e.sendRaw("AT\r\n", 5000);
    try std.testing.expectEqual(engine.AtStatus.ok, r.status);
    var it = r.lineIterator();
    try std.testing.expectEqualStrings("echo", it.next() orelse return error.Fail);
    try std.testing.expectEqualStrings("+CSQ: 1,99", it.next() orelse return error.Fail);
    try std.testing.expect(it.next() == null);
}

test "lineIterator single line without newline in body" {
    var m = mock_mod.MockIo.init();
    var clock: u64 = 0;
    var e = Engine512().init(m.io(), FakeTime{ .ms = &clock });
    m.feed("only\r\nOK\r\n");
    const r = e.sendRaw("AT\r\n", 5000);
    try std.testing.expectEqual(engine.AtStatus.ok, r.status);
    try std.testing.expectEqualStrings("only", r.body);
    var it = r.lineIterator();
    try std.testing.expectEqualStrings("only", it.next() orelse return error.Fail);
    try std.testing.expect(it.next() == null);
}

test "pumpUrcs drains mock rx before next command" {
    var m = mock_mod.MockIo.init();
    var clock: u64 = 0;
    var e = Engine512().init(m.io(), FakeTime{ .ms = &clock });
    m.feed("+CREG: 1\r\n");
    e.pumpUrcs();
    m.feed("OK\r\n");
    const r = e.sendRaw("AT\r\n", 5000);
    try std.testing.expectEqual(engine.AtStatus.ok, r.status);
    try std.testing.expectEqualStrings("", r.body);
}

test "pumpUrcs exits on read length zero" {
    var m = mock_mod.MockIo.init();
    var stub: PumpFirstReadZero = .{ .mock = &m };
    var clock: u64 = 0;
    var e = Engine512().init(stub.io(), FakeTime{ .ms = &clock });
    m.feed("SHOULD_NOT_CONSUME\r\n");
    e.pumpUrcs();
    try std.testing.expect(m.rx_pos == 0);
}

test "pumpUrcs catch break on read error after data" {
    var m = mock_mod.MockIo.init();
    m.feed("abc");
    var stub: PumpReadThenError = .{ .mock = &m };
    var clock: u64 = 0;
    var e = Engine512().init(stub.io(), FakeTime{ .ms = &clock });
    e.pumpUrcs();
    try std.testing.expectEqual(m.rx_len, m.rx_pos);
    try std.testing.expectEqual(@as(usize, 3), m.rx_pos);
}

test "setIo switches transport" {
    var m1 = mock_mod.MockIo.init();
    var m2 = mock_mod.MockIo.init();
    var clock: u64 = 0;
    var e = Engine512().init(m1.io(), FakeTime{ .ms = &clock });
    m2.feed("OK\r\n");
    e.setIo(m2.io());
    const r = e.sendRaw("X\r\n", 5000);
    try std.testing.expectEqual(engine.AtStatus.ok, r.status);
    try std.testing.expectEqualStrings("X\r\n", m2.sent());
    try std.testing.expectEqualStrings("", m1.sent());
}

test "timeout returns partial body trimmed" {
    var m = mock_mod.MockIo.init();
    var clock: u64 = 0;
    var e = Engine512().init(m.io(), FakeTime{ .ms = &clock });
    m.feed("no_terminal_yet\r\n");
    const r = e.sendRaw("AT\r\n", 16);
    try std.testing.expectEqual(engine.AtStatus.timeout, r.status);
    try std.testing.expectEqualStrings("no_terminal_yet", r.body);
}
