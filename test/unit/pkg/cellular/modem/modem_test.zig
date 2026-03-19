//! Integration tests: Modem wires MockIo into AtEngine and provides
//! SIM / IMEI / signal queries via its public API.

const std = @import("std");
const embed = @import("embed");
const modem_mod = embed.pkg.cellular.modem.modem_mod;
const mock_mod = embed.pkg.cellular.io.mock;
const commands = embed.pkg.cellular.at.commands;
const engine = embed.pkg.cellular.at.engine;
const types = embed.pkg.cellular.types;

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

fn ModemUnderTest() type {
    return modem_mod.Modem(
        struct {},
        struct {},
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
    try m.enterCmux();
    try std.testing.expect(m.pppIo() != null);
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
