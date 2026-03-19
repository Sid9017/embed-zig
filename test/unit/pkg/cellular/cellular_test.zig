//! Integration tests: `Cellular.tick()` bootstrap path with MockIo (one AT per tick).
//! Real-device log parity: `test/firmware/110-cellular/app.zig` step `[step4-cellFsm]` should show the same phase order.

const std = @import("std");
const embed = @import("embed");
const types = embed.pkg.cellular.types;
const cellular_mod = embed.pkg.cellular.cellular_mod;
const modem_mod = embed.pkg.cellular.modem.modem_mod;
const mock_mod = embed.pkg.cellular.io.mock;
const bus = embed.pkg.event.bus;
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

fn ModemT() type {
    return modem_mod.Modem(
        NoOpThread,
        NoOpNotify,
        FakeTime,
        embed.pkg.cellular.modem.profiles.quectel,
        GpioPlaceholder,
        512,
    );
}

fn CellularT() type {
    return cellular_mod.Cellular(
        NoOpThread,
        NoOpNotify,
        FakeTime,
        embed.pkg.cellular.modem.profiles.quectel,
        GpioPlaceholder,
        512,
    );
}

const PayloadBuf = struct {
    items: [24]types.CellularPayload = undefined,
    len: usize = 0,

    fn push(ctx: ?*anyopaque, e: types.CellularPayload) void {
        const s: *PayloadBuf = @ptrCast(@alignCast(ctx.?));
        if (s.len < s.items.len) {
            s.items[s.len] = e;
            s.len += 1;
        }
    }

    fn injector(self: *PayloadBuf) bus.EventInjector(types.CellularPayload) {
        return .{ .ctx = self, .call = push };
    }
};

fn countPhaseTo(rec: *const PayloadBuf, to: types.CellularPhase) usize {
    var n: usize = 0;
    for (rec.items[0..rec.len]) |p| {
        if (p == .phase_changed and p.phase_changed.to == to) n += 1;
    }
    return n;
}

test "Cellular tick bootstrap: off through registered with seven ticks" {
    var mock = mock_mod.MockIo.init();
    var ms: u64 = 0;
    const modem = try ModemT().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    var rec = PayloadBuf{};
    var cell = CellularT().init(modem, rec.injector());

    cell.powerOn();
    try std.testing.expectEqual(types.CellularPhase.probing, cell.phase());
    try std.testing.expectEqual(@as(usize, 1), countPhaseTo(&rec, .probing));

    mock.feed("OK\r\n");
    cell.tick();
    try std.testing.expectEqual(types.CellularPhase.at_configuring, cell.phase());
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.ate0, cell.bootstrapStep());

    mock.feed("OK\r\n");
    cell.tick();
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.cmee, cell.bootstrapStep());

    mock.feed("OK\r\n");
    cell.tick();
    try std.testing.expectEqual(types.CellularPhase.checking_sim, cell.phase());
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.cpin, cell.bootstrapStep());

    mock.feed("\r\n+CPIN: READY\r\n\r\nOK\r\n");
    cell.tick();
    try std.testing.expectEqual(types.CellularPhase.registering, cell.phase());
    try std.testing.expectEqual(types.SimStatus.ready, cell.modemState().sim);
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.cereg, cell.bootstrapStep());

    var saw_sim: bool = false;
    for (rec.items[0..rec.len]) |p| {
        if (p == .sim_status_changed and p.sim_status_changed == .ready) saw_sim = true;
    }
    try std.testing.expect(saw_sim);

    mock.feed("\r\n+CEREG: 0,1\r\n\r\nOK\r\n");
    cell.tick();
    try std.testing.expectEqual(types.CellularPhase.registered, cell.phase());
    try std.testing.expectEqual(types.CellularRegStatus.registered_home, cell.modemState().registration);
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.done, cell.bootstrapStep());
    try std.testing.expectEqual(@as(usize, 1), countPhaseTo(&rec, .registered));

    const expect_tx =
        "AT\r\n" ++
        "ATE0\r\n" ++
        "AT+CMEE=2\r\n" ++
        "AT+CPIN?\r\n" ++
        "AT+CEREG?\r\n";
    try std.testing.expectEqualStrings(expect_tx, mock.sent());
}

test "Cellular tick when off does not touch modem" {
    var mock = mock_mod.MockIo.init();
    var ms: u64 = 0;
    const modem = try ModemT().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    var rec = PayloadBuf{};
    var cell = CellularT().init(modem, rec.injector());

    cell.tick();
    try std.testing.expectEqual(@as(usize, 0), mock.sent().len);
}

test "Cellular CPIN SIM PIN yields error payload" {
    var mock = mock_mod.MockIo.init();
    var ms: u64 = 0;
    const modem = try ModemT().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    var rec = PayloadBuf{};
    var cell = CellularT().init(modem, rec.injector());

    cell.powerOn();
    mock.feed("OK\r\n");
    cell.tick();
    mock.feed("OK\r\n");
    cell.tick();
    mock.feed("OK\r\n");
    cell.tick();
    mock.feed("\r\n+CPIN: SIM PIN\r\n\r\nOK\r\n");
    cell.tick();

    try std.testing.expectEqual(types.CellularPhase.@"error", cell.phase());
    try std.testing.expectEqual(types.ModemError.sim_pin_required, cell.modemState().error_reason.?);

    var saw_err: bool = false;
    for (rec.items[0..rec.len]) |p| {
        if (p == .@"error" and p.@"error" == .sim_pin_required) saw_err = true;
    }
    try std.testing.expect(saw_err);
}

test "Cellular CEREG searching then poll until registered" {
    var mock = mock_mod.MockIo.init();
    var ms: u64 = 0;
    const modem = try ModemT().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    var rec = PayloadBuf{};
    var cell = CellularT().init(modem, rec.injector());

    cell.powerOn();
    mock.feed("OK\r\n");
    cell.tick();
    mock.feed("OK\r\n");
    cell.tick();
    mock.feed("OK\r\n");
    cell.tick();
    mock.feed("\r\n+CPIN: READY\r\n\r\nOK\r\n");
    cell.tick();
    mock.feed("\r\n+CEREG: 0,2\r\n\r\nOK\r\n");
    cell.tick();

    try std.testing.expectEqual(types.CellularPhase.registering, cell.phase());
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.done, cell.bootstrapStep());
    try std.testing.expectEqual(types.CellularRegStatus.searching, cell.modemState().registration);

    mock.feed("\r\n+CEREG: 0,1\r\n\r\nOK\r\n");
    cell.tick();
    try std.testing.expectEqual(types.CellularPhase.registered, cell.phase());
    try std.testing.expectEqual(types.CellularRegStatus.registered_home, cell.modemState().registration);
}

test "Cellular powerOff resets and emits phase to off" {
    var mock = mock_mod.MockIo.init();
    var ms: u64 = 0;
    const modem = try ModemT().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    var rec = PayloadBuf{};
    var cell = CellularT().init(modem, rec.injector());

    cell.powerOn();
    rec.len = 0;
    cell.powerOff();
    try std.testing.expectEqual(types.CellularPhase.off, cell.phase());
    try std.testing.expectEqual(@as(usize, 1), countPhaseTo(&rec, .off));
}

// --- Event → reducer seeding → tick (next AT) --------------------------------

test "seed at_configuring+ate0 via events then tick sends ATE0" {
    var mock = mock_mod.MockIo.init();
    var ms: u64 = 0;
    const modem = try ModemT().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    var rec = PayloadBuf{};
    var cell = CellularT().init(modem, rec.injector());

    cell.applyModemEvents(&.{ .power_on, .bootstrap_probe_ok });
    try std.testing.expectEqual(types.CellularPhase.at_configuring, cell.phase());
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.ate0, cell.bootstrapStep());

    mock.drain();
    mock.feed("OK\r\n");
    cell.tick();
    try std.testing.expectEqualStrings("ATE0\r\n", mock.sent());
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.cmee, cell.bootstrapStep());
}

test "seed at_configuring+cmee via events then tick sends CMEE" {
    var mock = mock_mod.MockIo.init();
    var ms: u64 = 0;
    const modem = try ModemT().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    var rec = PayloadBuf{};
    var cell = CellularT().init(modem, rec.injector());

    cell.applyModemEvents(&.{ .power_on, .bootstrap_probe_ok, .bootstrap_echo_ok });
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.cmee, cell.bootstrapStep());

    mock.drain();
    mock.feed("OK\r\n");
    cell.tick();
    try std.testing.expectEqualStrings("AT+CMEE=2\r\n", mock.sent());
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.cpin, cell.bootstrapStep());
}

test "seed checking_sim+cpin via events then tick sends CPIN" {
    var mock = mock_mod.MockIo.init();
    var ms: u64 = 0;
    const modem = try ModemT().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    var rec = PayloadBuf{};
    var cell = CellularT().init(modem, rec.injector());

    cell.applyModemEvents(&.{ .power_on, .bootstrap_probe_ok, .bootstrap_echo_ok, .bootstrap_cmee_ok });
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.cpin, cell.bootstrapStep());

    mock.drain();
    mock.feed("\r\n+CPIN: READY\r\n\r\nOK\r\n");
    cell.tick();
    try std.testing.expect(std.mem.endsWith(u8, mock.sent(), "AT+CPIN?\r\n"));
    try std.testing.expectEqual(types.CellularPhase.registering, cell.phase());
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.cereg, cell.bootstrapStep());
}

test "seed registering+cereg via events then tick sends CEREG" {
    var mock = mock_mod.MockIo.init();
    var ms: u64 = 0;
    const modem = try ModemT().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });
    var rec = PayloadBuf{};
    var cell = CellularT().init(modem, rec.injector());

    cell.applyModemEvents(&.{ .power_on, .bootstrap_probe_ok, .bootstrap_echo_ok, .bootstrap_cmee_ok, .{ .sim_status_reported = .ready } });
    try std.testing.expectEqual(types.CellularPhase.registering, cell.phase());
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.cereg, cell.bootstrapStep());

    mock.drain();
    mock.feed("\r\n+CEREG: 0,5\r\n\r\nOK\r\n");
    cell.tick();
    try std.testing.expectEqualStrings("AT+CEREG?\r\n", mock.sent());
    try std.testing.expectEqual(types.CellularPhase.registered, cell.phase());
    try std.testing.expectEqual(types.CellularRegStatus.registered_roaming, cell.modemState().registration);
}

test "cellularReduce power_on then bootstrap chain" {
    var s: cellular_mod.CellularFsmState = .{};
    cellular_mod.cellularReduce(&s, .power_on);
    try std.testing.expectEqual(types.CellularPhase.probing, s.modem.phase);
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.probe, s.bootstrap_step);

    cellular_mod.cellularReduce(&s, .bootstrap_probe_ok);
    try std.testing.expectEqual(types.CellularPhase.at_configuring, s.modem.phase);
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.ate0, s.bootstrap_step);

    cellular_mod.cellularReduce(&s, .bootstrap_echo_ok);
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.cmee, s.bootstrap_step);

    cellular_mod.cellularReduce(&s, .bootstrap_cmee_ok);
    try std.testing.expectEqual(types.CellularPhase.checking_sim, s.modem.phase);
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.cpin, s.bootstrap_step);

    cellular_mod.cellularReduce(&s, .{ .sim_status_reported = .ready });
    try std.testing.expectEqual(types.CellularPhase.registering, s.modem.phase);
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.cereg, s.bootstrap_step);

    cellular_mod.cellularReduce(&s, .{ .network_registration = .registered_home });
    try std.testing.expectEqual(types.CellularPhase.registered, s.modem.phase);
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.done, s.bootstrap_step);
}

test "cellularReduce bootstrap_at_error sets error" {
    var s: cellular_mod.CellularFsmState = .{};
    cellular_mod.cellularReduce(&s, .power_on);
    cellular_mod.cellularReduce(&s, .{ .bootstrap_at_error = .at_timeout });
    try std.testing.expectEqual(types.CellularPhase.@"error", s.modem.phase);
    try std.testing.expectEqual(types.ModemError.at_timeout, s.modem.error_reason.?);
}

test "cellularReduce retry from error goes to probing and clears at_timeout_count" {
    var s: cellular_mod.CellularFsmState = .{};
    cellular_mod.cellularReduce(&s, .power_on);
    s.modem.at_timeout_count = 7;
    cellular_mod.cellularReduce(&s, .{ .bootstrap_at_error = .at_fatal });
    try std.testing.expectEqual(types.CellularPhase.@"error", s.modem.phase);
    cellular_mod.cellularReduce(&s, .retry);
    try std.testing.expectEqual(types.CellularPhase.probing, s.modem.phase);
    try std.testing.expect(s.modem.error_reason == null);
    try std.testing.expectEqual(@as(u8, 0), s.modem.at_timeout_count);
    try std.testing.expectEqual(cellular_mod.InitSequenceStep.probe, s.bootstrap_step);
}

test "cellularReduce network_registration denied sets registration_denied" {
    var s: cellular_mod.CellularFsmState = .{};
    cellular_mod.cellularReduce(&s, .power_on);
    cellular_mod.cellularReduce(&s, .bootstrap_probe_ok);
    cellular_mod.cellularReduce(&s, .bootstrap_echo_ok);
    cellular_mod.cellularReduce(&s, .bootstrap_cmee_ok);
    cellular_mod.cellularReduce(&s, .{ .sim_status_reported = .ready });
    cellular_mod.cellularReduce(&s, .{ .network_registration = .denied });
    try std.testing.expectEqual(types.CellularPhase.@"error", s.modem.phase);
    try std.testing.expectEqual(types.ModemError.registration_denied, s.modem.error_reason.?);
}

test "cellularReduce dial_requested dial_succeeded dial_failed ip_lost" {
    var s: cellular_mod.CellularFsmState = .{};
    cellular_mod.cellularReduce(&s, .power_on);
    cellular_mod.cellularReduce(&s, .bootstrap_probe_ok);
    cellular_mod.cellularReduce(&s, .bootstrap_echo_ok);
    cellular_mod.cellularReduce(&s, .bootstrap_cmee_ok);
    cellular_mod.cellularReduce(&s, .{ .sim_status_reported = .ready });
    cellular_mod.cellularReduce(&s, .{ .network_registration = .registered_home });
    cellular_mod.cellularReduce(&s, .dial_requested);
    try std.testing.expectEqual(types.CellularPhase.dialing, s.modem.phase);
    cellular_mod.cellularReduce(&s, .dial_succeeded);
    try std.testing.expectEqual(types.CellularPhase.connected, s.modem.phase);
    cellular_mod.cellularReduce(&s, .ip_lost);
    try std.testing.expectEqual(types.CellularPhase.registered, s.modem.phase);
    cellular_mod.cellularReduce(&s, .dial_requested);
    cellular_mod.cellularReduce(&s, .dial_failed);
    try std.testing.expectEqual(types.CellularPhase.registered, s.modem.phase);
    cellular_mod.cellularReduce(&s, .dial_requested);
    cellular_mod.cellularReduce(&s, .ip_obtained);
    try std.testing.expectEqual(types.CellularPhase.connected, s.modem.phase);
}

test "cellularReduce dial_requested ignored when not registered" {
    var s: cellular_mod.CellularFsmState = .{};
    cellular_mod.cellularReduce(&s, .power_on);
    cellular_mod.cellularReduce(&s, .dial_requested);
    try std.testing.expectEqual(types.CellularPhase.probing, s.modem.phase);
}
