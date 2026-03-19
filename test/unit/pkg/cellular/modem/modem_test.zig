//! Integration tests: Modem wires MockIo into AtEngine and provides
//! SIM / IMEI / signal queries via its public API.

const std = @import("std");
const embed = @import("embed");
const modem_mod = embed.pkg.cellular.modem.modem_mod;
const mock_mod = embed.pkg.cellular.io.mock;
const commands = embed.pkg.cellular.at.commands;
const engine = embed.pkg.cellular.at.engine;
const types = embed.pkg.cellular.types;
const cmux_mod = embed.pkg.cellular.at.cmux;
const thread_mod = embed.runtime.thread;

const FakeTime = struct {
    ms: *u64,
    pub fn nowMs(self: FakeTime) u64 {
        return self.ms.*;
    }
    pub fn sleepMs(self: FakeTime, delta: u32) void {
        self.ms.* +%= delta;
    }
};

const GpioPlaceholder = struct {};

/// No-op thread for tests: spawn does not run the task so tests drive pump() explicitly.
const NoOpThread = struct {
    pub fn spawn(_: thread_mod.SpawnConfig, _: thread_mod.TaskFn, _: ?*anyopaque) anyerror!NoOpThread {
        return .{};
    }
    pub fn join(_: *NoOpThread) void {}
    pub fn detach(_: *NoOpThread) void {}
};

/// Notify stub for CMUX tests: init required by Modem; timedWait/signal used by channel poll.
const NoOpNotify = struct {
    pub fn init() NoOpNotify {
        return .{};
    }
    pub fn timedWait(_: *NoOpNotify, _: u64) bool {
        return false;
    }
    pub fn signal(_: *NoOpNotify) void {}
};

fn ModemUnderTest() type {
    return modem_mod.Modem(
        NoOpThread,
        NoOpNotify,
        FakeTime,
        embed.pkg.cellular.modem.profiles.quectel,
        GpioPlaceholder,
        512,
    );
}

// ---------------------------------------------------------------------------
// Step 8 routing (MD-xx)
// ---------------------------------------------------------------------------

test "MD-03: invalid init returns NoIo when neither io nor at_io" {
    var ms: u64 = 0;
    const result = ModemUnderTest().init(.{
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    try std.testing.expectError(error.NoIo, result);
}

test "MD-01: single-ch init with .io only, mode is single_channel" {
    var mock = mock_mod.MockIo.init();
    mock.feed("OK\r\n");
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    try std.testing.expectEqual(.single_channel, m.mode());
    try std.testing.expect(m.pppIo() == null);
}

test "MD-02: multi-ch init with at_io + data_io, mode is multi_channel" {
    var mock_at = mock_mod.MockIo.init();
    var mock_data = mock_mod.MockIo.init();
    mock_at.feed("OK\r\n");
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{
        .at_io = mock_at.io(),
        .data_io = mock_data.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    try std.testing.expectEqual(.multi_channel, m.mode());
    try std.testing.expect(m.pppIo() != null);
}

test "MD-07: multi-ch pppIo available after init" {
    var mock_at = mock_mod.MockIo.init();
    var mock_data = mock_mod.MockIo.init();
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{
        .at_io = mock_at.io(),
        .data_io = mock_data.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    const ppp = m.pppIo();
    try std.testing.expect(ppp != null);
}

test "MD-06: multi-ch PPP write goes only to data_io" {
    var mock_at = mock_mod.MockIo.init();
    var mock_data = mock_mod.MockIo.init();
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{
        .at_io = mock_at.io(),
        .data_io = mock_data.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    const ppp = m.pppIo().?;
    _ = ppp.write("x") catch @panic("write");
    try std.testing.expectEqualStrings("x", mock_data.sent());
    try std.testing.expectEqual(@as(usize, 0), mock_at.sent().len);
}

test "MD-12: multi-ch enterCmux is no-op" {
    var mock_at = mock_mod.MockIo.init();
    var mock_data = mock_mod.MockIo.init();
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{
        .at_io = mock_at.io(),
        .data_io = mock_data.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    switch (m.enterCmux()) {
        .ok => {},
        .err => |e| std.debug.panic("enterCmux: {s} {s}", .{ @tagName(e.status), e.body }),
    }
    try std.testing.expect(m.pppIo() != null);
}

// ---------------------------------------------------------------------------
// Step 10 single-channel CMUX (MD-08～MD-11). Default config: dlci 1=ppp, 2=at.
// ---------------------------------------------------------------------------

/// Feeds OK plus Basic-mode (0xF9) UA for default single-ch config (DLCI 1).
/// Pads with zeros so the post-AT+CMUX=0 drain in enterCmux does not consume the UA.
fn feedOkAndUas(mock: *mock_mod.MockIo) void {
    mock.feed("OK\r\n");
    var pad: [64]u8 = undefined;
    @memset(&pad, 0);
    mock.feed(&pad);
    var buf: [64]u8 = undefined;
    const ua1 = cmux_mod.encodeFrameBasic(.{
        .dlci = 1,
        .control = @intFromEnum(cmux_mod.FrameType.ua),
        .data = &.{},
    }, &buf);
    mock.feed(buf[0..ua1]);
}

test "MD-08: single-ch enterCmux sends AT+CMUX=0, UAs fed, isCmuxActive true" {
    var mock = mock_mod.MockIo.init();
    mock.max_read_per_call = 4;
    feedOkAndUas(&mock);
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    try std.testing.expectEqual(.single_channel, m.mode());
    switch (m.enterCmux()) {
        .ok => {},
        .err => |e| std.debug.panic("enterCmux: {s} {s}", .{ @tagName(e.status), e.body }),
    }
    try std.testing.expect(m.isCmuxActive());
    try std.testing.expect(std.mem.indexOf(u8, mock.sent(), "AT+CMUX=0") != null);
}

test "MD-09: single-ch CMUX AT: enterCmux then sendRaw, AT goes over CMUX channel" {
    var mock = mock_mod.MockIo.init();
    mock.max_read_per_call = 4;
    feedOkAndUas(&mock);
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    switch (m.enterCmux()) {
        .ok => {},
        .err => |e| std.debug.panic("enterCmux: {s} {s}", .{ @tagName(e.status), e.body }),
    }
    mock.max_read_per_call = null;
    var resp_buf: [64]u8 = undefined;
    const ui_len = cmux_mod.encodeFrameBasic(.{
        .dlci = 1,
        .control = 0xEF,
        .data = "\r\nOK\r\n",
    }, &resp_buf);
    mock.feed(resp_buf[0..ui_len]);
    m.pump();
    const r = m.at().sendRaw("AT\r\n", 10_000);
    try std.testing.expectEqual(engine.AtStatus.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, mock.sent(), "AT\r\n") != null);
}

test "MD-10: single-ch CMUX (AT only) pppIo stays null after enterCmux" {
    var mock = mock_mod.MockIo.init();
    mock.max_read_per_call = 4;
    feedOkAndUas(&mock);
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    try std.testing.expect(m.pppIo() == null);
    switch (m.enterCmux()) {
        .ok => {},
        .err => |e| std.debug.panic("enterCmux: {s} {s}", .{ @tagName(e.status), e.body }),
    }
    try std.testing.expect(m.pppIo() == null);
}

test "MD-11: single-ch exitCmux restores raw Io, isCmuxActive false, pppIo null" {
    var mock = mock_mod.MockIo.init();
    mock.max_read_per_call = 4;
    feedOkAndUas(&mock);
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    switch (m.enterCmux()) {
        .ok => {},
        .err => |e| std.debug.panic("enterCmux: {s} {s}", .{ @tagName(e.status), e.body }),
    }
    try std.testing.expect(m.isCmuxActive());
    m.exitCmux();
    try std.testing.expect(!m.isCmuxActive());
    try std.testing.expect(m.pppIo() == null);
    mock.feed("OK\r\n");
    try std.testing.expect(m.at().sendRaw("AT\r\n", 10_000).status == .ok);
}

// ---------------------------------------------------------------------------
// AT engine wiring (existing tests; MD-04 / MD-05)
// ---------------------------------------------------------------------------

test "modem.at sendRaw over MockIo: command written, OK parsed" {
    var mock = mock_mod.MockIo.init();
    mock.feed("OK\r\n");
    var ms: u64 = 0;

    var m = try ModemUnderTest().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });

    const r = m.at().sendRaw("AT\r\n", 10_000);
    try std.testing.expectEqual(engine.AtStatus.ok, r.status);
    try std.testing.expectEqualStrings("AT\r\n", mock.sent());
}

test "modem.at send(Probe): typed path uses same Io" {
    var mock = mock_mod.MockIo.init();
    mock.feed("OK\r\n");
    var ms: u64 = 0;

    var m = try ModemUnderTest().init(.{
        .at_io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });

    const out = m.at().send(commands.Probe, {});
    try std.testing.expectEqual(engine.AtStatus.ok, out.status);
    try std.testing.expectEqualStrings("AT\r\n", mock.sent());
}

test "modem.at sendRaw: CME ERROR propagated" {
    var mock = mock_mod.MockIo.init();
    mock.feed("\r\n+CME ERROR: 123\r\n");
    var ms: u64 = 0;

    var m = try ModemUnderTest().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });

    const r = m.at().sendRaw("AT\r\n", 10_000);
    try std.testing.expectEqual(engine.AtStatus.cme_error, r.status);
    try std.testing.expectEqual(@as(u16, 123), r.error_code.?);
}

test "modem init prefers at_io over io" {
    var mock_at = mock_mod.MockIo.init();
    var mock_data = mock_mod.MockIo.init();
    mock_at.feed("OK\r\n");
    var ms: u64 = 0;

    var m = try ModemUnderTest().init(.{
        .io = mock_data.io(),
        .at_io = mock_at.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });

    _ = m.at().sendRaw("AT\r\n", 10_000);
    try std.testing.expectEqualStrings("AT\r\n", mock_at.sent());
    try std.testing.expectEqual(@as(usize, 0), mock_data.sent().len);
}

// ---------------------------------------------------------------------------
// SIM queries (Step 5)
// ---------------------------------------------------------------------------

test "modem getSimStatus returns ready" {
    var mock = mock_mod.MockIo.init();
    mock.feed("\r\n+CPIN: READY\r\n\r\nOK\r\n");
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{ .io = mock.io(), .time = .{ .ms = &ms }, .gpio = null });
    const status = try m.getSimStatus();
    try std.testing.expectEqual(types.SimStatus.ready, status);
}

test "modem getSimStatus returns pin_required" {
    var mock = mock_mod.MockIo.init();
    mock.feed("\r\n+CPIN: SIM PIN\r\n\r\nOK\r\n");
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{ .io = mock.io(), .time = .{ .ms = &ms }, .gpio = null });
    const status = try m.getSimStatus();
    try std.testing.expectEqual(types.SimStatus.pin_required, status);
}

test "modem getSimStatus returns not_inserted" {
    var mock = mock_mod.MockIo.init();
    mock.feed("\r\n+CPIN: NOT INSERTED\r\n\r\nOK\r\n");
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{ .io = mock.io(), .time = .{ .ms = &ms }, .gpio = null });
    const status = try m.getSimStatus();
    try std.testing.expectEqual(types.SimStatus.not_inserted, status);
}

test "modem getSimStatus returns error on AT failure" {
    var mock = mock_mod.MockIo.init();
    mock.feed("\r\nERROR\r\n");
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{ .io = mock.io(), .time = .{ .ms = &ms }, .gpio = null });
    try std.testing.expectError(error.AtError, m.getSimStatus());
}

test "modem getImsi returns valid IMSI" {
    var mock = mock_mod.MockIo.init();
    mock.feed("\r\n460030912345678\r\n\r\nOK\r\n");
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{ .io = mock.io(), .time = .{ .ms = &ms }, .gpio = null });
    const imsi = try m.getImsi();
    try std.testing.expectEqualStrings("460030912345678", imsi);
}

test "modem getImsi returns error on timeout" {
    var mock = mock_mod.MockIo.init();
    _ = &mock;
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{ .io = mock.io(), .time = .{ .ms = &ms }, .gpio = null });
    try std.testing.expectError(error.Timeout, m.getImsi());
}

test "modem getIccid returns valid ICCID" {
    var mock = mock_mod.MockIo.init();
    mock.feed("\r\n+CCID: 89860012345678901234\r\n\r\nOK\r\n");
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{ .io = mock.io(), .time = .{ .ms = &ms }, .gpio = null });
    const iccid = try m.getIccid();
    try std.testing.expectEqualStrings("89860012345678901234", iccid);
}

// ---------------------------------------------------------------------------
// IMEI query
// ---------------------------------------------------------------------------

test "modem getImei returns valid IMEI" {
    var mock = mock_mod.MockIo.init();
    mock.feed("\r\n860123456789012\r\n\r\nOK\r\n");
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{ .io = mock.io(), .time = .{ .ms = &ms }, .gpio = null });
    const imei = try m.getImei();
    try std.testing.expectEqualStrings("860123456789012", imei);
}

test "modem getImei returns error on AT failure" {
    var mock = mock_mod.MockIo.init();
    mock.feed("\r\nERROR\r\n");
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{ .io = mock.io(), .time = .{ .ms = &ms }, .gpio = null });
    try std.testing.expectError(error.AtError, m.getImei());
}

// ---------------------------------------------------------------------------
// Signal queries (Step 6)
// ---------------------------------------------------------------------------

test "modem getSignal normal signal" {
    var mock = mock_mod.MockIo.init();
    mock.feed("\r\n+CSQ: 20,0\r\n\r\nOK\r\n");
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{ .io = mock.io(), .time = .{ .ms = &ms }, .gpio = null });
    const info = try m.getSignal();
    try std.testing.expectEqual(@as(i8, -73), info.rssi);
    try std.testing.expectEqual(@as(?u8, 0), info.ber);
}

test "modem getSignal weak signal" {
    var mock = mock_mod.MockIo.init();
    mock.feed("\r\n+CSQ: 5,0\r\n\r\nOK\r\n");
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{ .io = mock.io(), .time = .{ .ms = &ms }, .gpio = null });
    const info = try m.getSignal();
    try std.testing.expectEqual(@as(i8, -103), info.rssi);
}

test "modem getSignal strong signal" {
    var mock = mock_mod.MockIo.init();
    mock.feed("\r\n+CSQ: 31,0\r\n\r\nOK\r\n");
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{ .io = mock.io(), .time = .{ .ms = &ms }, .gpio = null });
    const info = try m.getSignal();
    try std.testing.expectEqual(@as(i8, -51), info.rssi);
}

test "modem getSignal with BER" {
    var mock = mock_mod.MockIo.init();
    mock.feed("\r\n+CSQ: 15,3\r\n\r\nOK\r\n");
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{ .io = mock.io(), .time = .{ .ms = &ms }, .gpio = null });
    const info = try m.getSignal();
    try std.testing.expectEqual(@as(i8, -83), info.rssi);
    try std.testing.expectEqual(@as(?u8, 3), info.ber);
}

test "modem getSignal not detectable returns NoSignal" {
    var mock = mock_mod.MockIo.init();
    mock.feed("\r\n+CSQ: 99,99\r\n\r\nOK\r\n");
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{ .io = mock.io(), .time = .{ .ms = &ms }, .gpio = null });
    try std.testing.expectError(error.NoSignal, m.getSignal());
}

test "modem getSignal error on AT failure" {
    var mock = mock_mod.MockIo.init();
    mock.feed("\r\nERROR\r\n");
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{ .io = mock.io(), .time = .{ .ms = &ms }, .gpio = null });
    try std.testing.expectError(error.AtError, m.getSignal());
}

test "modem getLastSignal returns cached value" {
    var mock = mock_mod.MockIo.init();
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{ .io = mock.io(), .time = .{ .ms = &ms }, .gpio = null });

    try std.testing.expectEqual(@as(?types.CellularSignalInfo, null), m.getLastSignal());

    mock.feed("\r\n+CSQ: 20,0\r\n\r\nOK\r\n");
    const info = try m.getSignal();
    const cached = m.getLastSignal();
    try std.testing.expect(cached != null);
    try std.testing.expectEqual(info.rssi, cached.?.rssi);
    try std.testing.expectEqual(info.ber, cached.?.ber);
}
