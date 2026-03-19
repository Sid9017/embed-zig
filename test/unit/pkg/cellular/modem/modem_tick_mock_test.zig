//! Mock-driven sequence for the first Modem tick path: probe → echo off → CMEE → CPIN? → CEREG?.
//! One AT per step; MockIo.feed() supplies modem responses before each `send`. Not a real tick() yet.

const std = @import("std");
const embed = @import("embed");
const modem_mod = embed.pkg.cellular.modem.modem_mod;
const mock_mod = embed.pkg.cellular.io.mock;
const commands = embed.pkg.cellular.at.commands;
const engine = embed.pkg.cellular.at.engine;
const types = embed.pkg.cellular.types;
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

const NoOpThread = struct {
    pub fn spawn(_: thread_mod.SpawnConfig, _: thread_mod.TaskFn, _: ?*anyopaque) anyerror!NoOpThread {
        return .{};
    }
    pub fn join(_: *NoOpThread) void {}
    pub fn detach(_: *NoOpThread) void {}
};

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

test "tick path mock: Probe then ATE0 then CMEE then CPIN then CEREG" {
    var mock = mock_mod.MockIo.init();
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    const at = m.at();

    mock.feed("OK\r\n");
    {
        const o = at.send(commands.Probe, {});
        try std.testing.expectEqual(engine.AtStatus.ok, o.status);
    }

    mock.feed("OK\r\n");
    {
        const o = at.send(commands.SetEchoOff, {});
        try std.testing.expectEqual(engine.AtStatus.ok, o.status);
    }

    mock.feed("OK\r\n");
    {
        const o = at.send(commands.SetCmeErrorVerbose, {});
        try std.testing.expectEqual(engine.AtStatus.ok, o.status);
    }

    mock.feed("\r\n+CPIN: READY\r\n\r\nOK\r\n");
    {
        const o = at.send(commands.GetCpin, {});
        try std.testing.expectEqual(engine.AtStatus.ok, o.status);
        try std.testing.expectEqual(types.SimStatus.ready, o.value.?);
    }

    mock.feed("\r\n+CEREG: 0,1\r\n\r\nOK\r\n");
    {
        const o = at.send(commands.GetCereg, {});
        try std.testing.expectEqual(engine.AtStatus.ok, o.status);
        try std.testing.expectEqual(types.CellularRegStatus.registered_home, o.value.?);
    }

    const expect_tx =
        "AT\r\n" ++
        "ATE0\r\n" ++
        "AT+CMEE=2\r\n" ++
        "AT+CPIN?\r\n" ++
        "AT+CEREG?\r\n";
    try std.testing.expectEqualStrings(expect_tx, mock.sent());
}

test "tick path mock: CREG instead of CEREG (roaming stat 5)" {
    var mock = mock_mod.MockIo.init();
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });

    mock.feed("OK\r\n");
    _ = m.at().send(commands.Probe, {});

    mock.feed("\r\n+CREG: 0,5\r\n\r\nOK\r\n");
    const o = m.at().send(commands.GetCreg, {});
    try std.testing.expectEqual(engine.AtStatus.ok, o.status);
    try std.testing.expectEqual(types.CellularRegStatus.registered_roaming, o.value.?);
    try std.testing.expect(std.mem.endsWith(u8, mock.sent(), "AT+CREG?\r\n"));
}

test "tick path mock: CPIN requests PIN" {
    var mock = mock_mod.MockIo.init();
    var ms: u64 = 0;
    var m = try ModemUnderTest().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });

    mock.feed("\r\n+CPIN: SIM PIN\r\n\r\nOK\r\n");
    const o = m.at().send(commands.GetCpin, {});
    try std.testing.expectEqual(engine.AtStatus.ok, o.status);
    try std.testing.expectEqual(types.SimStatus.pin_required, o.value.?);
}
