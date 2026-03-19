//! 110-cellular firmware — UART setup, link check, then real-device multichannel or mock.
//!
//! Step 0: UART/modem power ready. Step 2: Io probe (AT). Step 3: parse (CSQ, CPIN, CREG, CGREG, CEREG).
//!
//! **Real device** (when hw has reconfigureUartBaud, e.g. h106_tiga_v4):
//! 1. [step-baud] Raise baud: send AT+IPR=921600, then reconfigure UART to 921600.
//! 2. [step-cmuxOn] Enter CMUX (single UART -> logical multichannel); do not exit.
//! 3. [step4-cellFsm] Bootstrap + EPS registration — all AT over CMUX multichannel.
//! 4. [step5-identity] IMEI/IMSI/ICCID — over CMUX.
//! 5. [step-cmuxOff] exitCmux.
//!
//! Log tags: [step0-uartSetup], [step2-ioTest], [step3-parseTest], [step-baud], [step-cmuxOn], [step4-cellFsm], [step5-identity], [step-cmuxOff].

const board_spec = @import("board_spec.zig");
const esp = @import("esp");
const embed = esp.embed;
const io_mod = embed.pkg.cellular.io.io_mod;
const parse = embed.pkg.cellular.at.parse;
const std = @import("std");
const thread_mod = embed.runtime.thread;

/// No-op thread for single-thread firmware: spawn does not run task; use modem.pump() when CMUX active.
const NoOpThread = struct {
    pub fn spawn(_: thread_mod.SpawnConfig, _: thread_mod.TaskFn, _: ?*anyopaque) anyerror!NoOpThread {
        return .{};
    }
    pub fn join(_: *NoOpThread) void {}
    pub fn detach(_: *NoOpThread) void {}
};

/// Notify stub for CMUX (init + timedWait/signal used by channel poll).
const NoOpNotify = struct {
    pub fn init() NoOpNotify {
        return .{};
    }
    pub fn timedWait(_: *NoOpNotify, _: u64) bool {
        return false;
    }
    pub fn signal(_: *NoOpNotify) void {}
};

const step0_tag = "[step0-uartSetup]";
const step2_tag = "[step2-ioTest]";
const step3_tag = "[step3-parseTest]";
const step_baud_tag = "[step-baud]";
const step_cmux_on_tag = "[step-cmuxOn]";
const step4_tag = "[step4-cellFsm]";
const step5_tag = "[step5-identity]";
const step_cmux_off_tag = "[step-cmuxOff]";
/// Mock-only: modem routing check (real device uses step_baud -> step_cmuxOn -> step4/5).
const step8_tag = "[step8-modemRouting]";

/// Placeholder GPIO for modem/cellular (no pin control in this app). Shared so ModemT and CellularT use the same type.
const GpioPh = struct {};

/// Bootstrap segments: probing, at_configuring, checking_sim, registering.
const step4_state_total: u32 = 4;
/// Safety cap per segment (in case the modem never advances).
const step4_max_ticks_per_state: u32 = 400;
const step4_sleep_between_ticks_ms: u32 = 20;
/// Longer sleep between ticks while `registering` and `bootstrap_step == .done` (post–first CEREG, still searching).
const step4_reg_poll_interval_ms: u32 = 3000;

/// Set to true to run step2 (AT probe) and step3 (parse) before baud/CMUX; false when pre-steps are already verified.
const run_burnin_steps = false;

/// Main-thread only. Large on-stack RX/fold buffers exhaust ESP-IDF main task stack (~3584 B)
/// when combined with fmt/log frames; use BSS instead.
var g_cellular_rx: [384]u8 = undefined;
var g_cellular_fold: [384]u8 = undefined;
/// Single BSS buffer for AT/AT+IPR response accumulation (sequential use only).
var g_ipr_accum: [256]u8 = undefined;
/// parseSummary must not return slices into stack locals (dangling); main-thread only.
var g_parse_summary: [96]u8 = undefined;
/// Max body length for log lines to avoid BSP format overflow.
const max_log_body_len: usize = 80;

pub fn run(comptime hw: type, env: anytype) void {
    _ = env;

    const Board = board_spec.Board(hw);
    const log: Board.log = .{};
    const time: Board.time = .{};

    hw.init() catch {
        log.errFmt("{s} [ERROR] hw init failed", .{step0_tag});
        return;
    };
    defer hw.deinit();

    const uart_ptr = hw.uart_cellular();
    const UartType = @TypeOf(uart_ptr.*);
    const io = io_mod.fromUart(UartType, uart_ptr);
    log.infoFmt("{s} [READY] uart_cellular ok, Io fromUart bound (modem power + uart per BSP)", .{step0_tag});

    if (run_burnin_steps) {
        time.sleepMs(3000);
        const cmd_at = "AT\r\n";
        log.infoFmt("{s} [SEND] {s}", .{ step2_tag, atCmdStripCrlf(cmd_at) });
        const t2 = time.nowMs();
        _ = io.write(cmd_at) catch |e| {
            log.infoFmt("{s} [ERROR] write:{s} ({d}ms)", .{ step2_tag, @errorName(e), elapsedMs(time, t2) });
            return;
        };
        time.sleepMs(500);
        const n2 = io.read(&g_cellular_rx) catch |e| {
            log.infoFmt("{s} [ERROR] read:{s} ({d}ms)", .{ step2_tag, @errorName(e), elapsedMs(time, t2) });
            return;
        };
        const body2 = foldWs(&g_cellular_fold, g_cellular_rx[0..n2]);
        log.infoFmt("{s} [RECV] {s} ({d}ms)", .{ step2_tag, body2, elapsedMs(time, t2) });
        testParseAt(io, time, log, "AT+CSQ\r\n");
        testParseAt(io, time, log, "AT+CPIN?\r\n");
        testParseAt(io, time, log, "AT+CREG?\r\n");
        testParseAt(io, time, log, "AT+CGREG?\r\n");
        testParseAt(io, time, log, "AT+CEREG?\r\n");
        log.infoFmt("{s} [DONE] step3 parse tests finished", .{step3_tag});
    } else {
        time.sleepMs(500);
    }

    if (comptime isMockCellularHw(hw)) {
        runCellularFsmMock(uart_ptr, Board.time, time, Board.log, log);
        return;
    }

    // --- Real device: raise baud -> reconnect UART -> enter CMUX -> all subsequent AT over multichannel ---
    var io_after_baud = io;
    if (comptime @hasDecl(hw, "reconfigureUartBaud")) {
        const baud_target = embed.pkg.cellular.types.BaudRate.b921600;
        const poll_interval_ms: u32 = 50;
        const at_wait_iters: u32 = 2000 / poll_interval_ms;

        log.infoFmt("{s} [WAIT] drain until RDY or 5s (modem boot)", .{step_baud_tag});
        const rdy_wait_iters: u32 = 5000 / poll_interval_ms;
        var rdy_len: u32 = 0;
        var rdy_seen = false;
        var ri: u32 = 0;
        while (ri < rdy_wait_iters) : (ri += 1) {
            const nr = io_after_baud.read(&g_cellular_rx) catch 0;
            if (nr > 0) {
                if (rdy_len + nr > g_ipr_accum.len) {
                    const drop = rdy_len + nr -| g_ipr_accum.len;
                    std.mem.copyForwards(u8, g_ipr_accum[0..], g_ipr_accum[drop..rdy_len]);
                    rdy_len = rdy_len -| drop;
                }
                const copy_len = @min(g_ipr_accum.len -| rdy_len, nr);
                std.mem.copyForwards(u8, g_ipr_accum[rdy_len..][0..copy_len], g_cellular_rx[0..copy_len]);
                rdy_len += copy_len;
                if (std.mem.indexOf(u8, g_ipr_accum[0..rdy_len], "RDY") != null) {
                    rdy_seen = true;
                    break;
                }
            }
            time.sleepMs(poll_interval_ms);
        }
        if (rdy_seen) log.infoFmt("{s} [WAIT] saw RDY, modem boot ready", .{step_baud_tag});
        time.sleepMs(200);

        log.infoFmt("{s} [SYNC] AT at current baud before AT+IPR", .{step_baud_tag});
        _ = io_after_baud.write("AT\r\n") catch |e| {
            log.errFmt("{s} [ERROR] AT write: {s}", .{ step_baud_tag, @errorName(e) });
            return;
        };
        time.sleepMs(150);
        var sync_len: u32 = 0;
        var at_ok = false;
        var i: u32 = 0;
        while (i < at_wait_iters) : (i += 1) {
            const nr = io_after_baud.read(&g_cellular_rx) catch 0;
            if (nr > 0) {
                if (sync_len + nr > g_ipr_accum.len) {
                    const drop = sync_len + nr -| g_ipr_accum.len;
                    std.mem.copyForwards(u8, g_ipr_accum[0..], g_ipr_accum[drop..sync_len]);
                    sync_len = sync_len -| drop;
                }
                const copy_len = @min(g_ipr_accum.len -| sync_len, nr);
                std.mem.copyForwards(u8, g_ipr_accum[sync_len..][0..copy_len], g_cellular_rx[0..copy_len]);
                sync_len += copy_len;
                const s = g_ipr_accum[0..sync_len];
                if (std.mem.indexOf(u8, s, "OK") != null or std.mem.indexOf(u8, s, "ok") != null) {
                    at_ok = true;
                    break;
                }
            }
            time.sleepMs(poll_interval_ms);
        }
        if (!at_ok) log.infoFmt("{s} [WARN] no OK to AT (modem may still boot); trying AT+IPR anyway", .{step_baud_tag});
        time.sleepMs(100);

        log.infoFmt("{s} [RAISE] sending AT+IPR={d} at current baud", .{ step_baud_tag, baud_target });
        _ = io_after_baud.write("AT+IPR=921600\r\n") catch |e| {
            log.errFmt("{s} [ERROR] AT+IPR write: {s}", .{ step_baud_tag, @errorName(e) });
            return;
        };
        time.sleepMs(200);
        const ipr_wait_ms: u32 = 2000;
        const ipr_max_iters = ipr_wait_ms / poll_interval_ms;
        var saw_ok = false;
        var saw_err = false;
        var accum_len: u32 = 0;
        var iter: u32 = 0;
        while (iter < ipr_max_iters) : (iter += 1) {
            const nr = io_after_baud.read(&g_cellular_rx) catch 0;
            if (nr > 0) {
                const to_copy = @min(nr, g_ipr_accum.len -| accum_len);
                if (to_copy < nr and accum_len > 0) {
                    const drop = accum_len + nr -| g_ipr_accum.len;
                    std.mem.copyForwards(u8, g_ipr_accum[0..], g_ipr_accum[drop..accum_len]);
                    accum_len = accum_len -| drop;
                }
                const copy_len = @min(g_ipr_accum.len -| accum_len, nr);
                std.mem.copyForwards(u8, g_ipr_accum[accum_len..][0..copy_len], g_cellular_rx[0..copy_len]);
                accum_len += copy_len;
                const slice = g_ipr_accum[0..accum_len];
                if (std.mem.indexOf(u8, slice, "ERROR") != null or std.mem.indexOf(u8, slice, "+CME ERROR") != null) {
                    saw_err = true;
                    break;
                }
                if (std.mem.indexOf(u8, slice, "OK") != null or std.mem.indexOf(u8, slice, "ok") != null) {
                    saw_ok = true;
                    break;
                }
            }
            time.sleepMs(poll_interval_ms);
        }
        if (saw_err) {
            log.errFmt("{s} [ERROR] modem replied ERROR to AT+IPR (e.g. baud not supported)", .{step_baud_tag});
            return;
        }
        if (!saw_ok) {
            log.errFmt("{s} [ERROR] no OK to AT+IPR within {d}ms; modem may not have switched baud", .{ step_baud_tag, ipr_wait_ms });
            if (accum_len > 0) {
                const max_log = @min(accum_len, 80);
                var buf: [80]u8 = undefined;
                for (g_ipr_accum[0..max_log], buf[0..max_log]) |c, *out| {
                    out.* = if (c >= 0x20 and c <= 0x7E) c else '.';
                }
                log.errFmt("{s} [DEBUG] received {d} bytes: {s}", .{ step_baud_tag, accum_len, buf[0..max_log] });
            } else {
                log.errFmt("{s} [DEBUG] received 0 bytes from modem", .{step_baud_tag});
            }
            return;
        }
        log.infoFmt("{s} [OK] modem replied OK at current baud, wait then switch UART", .{step_baud_tag});
        time.sleepMs(150);
        hw.reconfigureUartBaud(baud_target);
        log.infoFmt("{s} [RECONNECT] UART reconfigured to {d} baud", .{ step_baud_tag, baud_target });
        time.sleepMs(500);
        var empty_in_a_row: u32 = 0;
        var drain_reads: u32 = 0;
        while (drain_reads < 30 and empty_in_a_row < 5) {
            const n = io_after_baud.read(&g_cellular_rx) catch 0;
            if (n == 0) {
                empty_in_a_row += 1;
            } else {
                empty_in_a_row = 0;
            }
            drain_reads += 1;
            time.sleepMs(30);
        }
        if (drain_reads > 0) log.infoFmt("{s} [DRAIN] after reconfigure: {d} reads (clear URCs)", .{ step_baud_tag, drain_reads });
        log.infoFmt("{s} [PROBE] AT at new baud, then drain for enterCmux", .{step_baud_tag});
        _ = io_after_baud.write("AT\r\n") catch |e| {
            log.errFmt("{s} [ERROR] AT write at new baud: {s}", .{ step_baud_tag, @errorName(e) });
            return;
        };
        time.sleepMs(700);
        for (0..12) |_| {
            _ = io_after_baud.read(&g_cellular_rx) catch 0;
            time.sleepMs(50);
        }
        log.infoFmt("{s} [PROBE] drain done, buffer clear for AT+CMUX=0", .{step_baud_tag});
    }

    const ThreadT = if (@hasDecl(hw, "CellularThread")) hw.CellularThread else NoOpThread;
    const NotifyT = if (@hasDecl(hw, "CellularNotify")) hw.CellularNotify else NoOpNotify;
    // Pump stack 8192: pump calls io.read()/BSP + local rx[272] in Advanced path; overflow corrupts heap
    // and triggers StoreProhibited in idle's prvDeleteTCB when FreeRTOS frees the task stack.
    const pump_cfg: ?thread_mod.SpawnConfig = if (@hasDecl(hw, "CellularThread"))
        (if (@hasDecl(hw, "pump_spawn_config")) hw.pump_spawn_config else .{
            .allocator = std.heap.c_allocator,
            .stack_size = 8192,
            .name = "cmux_pump",
        })
    else
        null;

    const modem_mod = embed.pkg.cellular.modem.modem_mod;
    const quectel = embed.pkg.cellular.modem.profiles.quectel;
    const ModemT = modem_mod.Modem(ThreadT, NotifyT, @TypeOf(time), quectel, GpioPh, 1024);

    var modem = ModemT.init(.{
        .io = io_after_baud,
        .time = time,
        .gpio = null,
        .pump_spawn_config = pump_cfg,
        .config = .{ .use_main_thread_pump = false },
    }) catch |e| {
        log.errFmt("{s} Modem init failed: {s}", .{ step_cmux_on_tag, @errorName(e) });
        return;
    };

    {
        log.infoFmt("{s} [VERIFY] AT at 921600 (same io as AT+CMUX=0)", .{step_cmux_on_tag});
        const at_resp = modem.at().sendRaw("AT\r\n", 5000);
        if (at_resp.status != .ok) {
            const body = at_resp.body;
            const body_trim = body[0..@min(body.len, max_log_body_len)];
            log.errFmt("{s} [ERROR] AT at 921600 failed: status={s} body={s}", .{
                step_cmux_on_tag,
                @tagName(at_resp.status),
                body_trim,
            });
            return;
        }
        log.infoFmt("{s} [VERIFY] AT at 921600 -> ok", .{step_cmux_on_tag});
    }

    log.infoFmt("{s} [ENTER] enterCmux (single UART -> multichannel)", .{step_cmux_on_tag});
    switch (modem.enterCmux()) {
        .ok => {},
        .err => |e| {
            const body = e.body;
            const body_trim = body[0..@min(body.len, max_log_body_len)];
            log.errFmt("{s} [ERROR] enterCmux failed: status={s} body={s}", .{
                step_cmux_on_tag,
                @tagName(e.status),
                body_trim,
            });
            return;
        },
    }
    log.infoFmt("{s} [ACTIVE] CMUX on; all subsequent AT (bootstrap, identity) over multichannel", .{step_cmux_on_tag});

    // step4 (bootstrap) and step5 (identity) run over the CMUX AT channel: at_engine Io was switched to cmux.channelIo(at_dlci) in enterCmux().
    runCellularFsmWithModem(ThreadT, NotifyT, ModemT, &modem, @TypeOf(time), time, Board.log, log);

    modem.exitCmux();
    log.infoFmt("{s} [EXIT] exitCmux done", .{step_cmux_off_tag});
}

/// True for the unit-test mock board (`zig build test-110-cellular-firmware`).
fn isMockCellularHw(comptime hw: type) bool {
    return std.mem.eql(u8, hw.name, "mock_cellular");
}

/// Drive `Cellular` bootstrap using an existing modem (real device: modem already in CMUX, all AT over multichannel).
fn runCellularFsmWithModem(
    comptime ThreadT: type,
    comptime NotifyT: type,
    comptime ModemT: type,
    modem: *ModemT,
    comptime TimeT: type,
    time: TimeT,
    comptime LogT: type,
    log: LogT,
) void {
    const cellular_mod = embed.pkg.cellular.cellular_mod;
    const bus = embed.pkg.event.bus;
    const types = embed.pkg.cellular.types;
    const quectel = embed.pkg.cellular.modem.profiles.quectel;
    const CellularT = cellular_mod.Cellular(ThreadT, NotifyT, TimeT, quectel, GpioPh, 1024);

    const injector = bus.EventInjector(types.CellularPayload){
        .ctx = null,
        .call = struct {
            fn f(_: ?*anyopaque, _: types.CellularPayload) void {}
        }.f,
    };

    var cell = CellularT.init(modem.*, injector);

    log.infoFmt("{s} [START] bootstrap + EPS poll until registered (all AT over CMUX multichannel)", .{step4_tag});
    cell.powerOn();
    var prev_sim: embed.pkg.cellular.types.SimStatus = .not_inserted;
    logCellFsmBoot(LogT, log, &cell);

    if (runCellularStateSegment(LogT, log, time, 1, &cell, &prev_sim)) {
        logCellFsmFinale(LogT, log, &cell);
        return;
    }
    if (runCellularStateSegment(LogT, log, time, 2, &cell, &prev_sim)) {
        logCellFsmFinale(LogT, log, &cell);
        return;
    }
    if (runCellularStateSegment(LogT, log, time, 3, &cell, &prev_sim)) {
        logCellFsmFinale(LogT, log, &cell);
        return;
    }
    if (runCellularStateSegment(LogT, log, time, 4, &cell, &prev_sim)) {
        logCellFsmFinale(LogT, log, &cell);
        return;
    }

    if (cell.phase() == .registered) {
        log.infoFmt("{s} EPS registered!", .{step4_tag});
    }

    logCellFsmFinale(LogT, log, &cell);

    if (cell.phase() == .registered) {
        queryAndLogIdentifiers(LogT, log, &cell);
    }
}

/// Drive `Cellular` bootstrap: per `[STATE=N/4]`, tick until leaving that phase or `error`. (Creates its own modem; used only from mock path or legacy.)
fn runCellularFsm(
    io: io_mod.Io,
    comptime TimeT: type,
    time: TimeT,
    comptime LogT: type,
    log: LogT,
) void {
    const modem_mod = embed.pkg.cellular.modem.modem_mod;
    const quectel = embed.pkg.cellular.modem.profiles.quectel;
    const ModemT = modem_mod.Modem(NoOpThread, NoOpNotify, TimeT, quectel, GpioPh, 1024);
    var modem = ModemT.init(.{ .io = io, .time = time, .gpio = null }) catch |e| {
        log.errFmt("{s} Modem init failed: {s}", .{ step4_tag, @errorName(e) });
        return;
    };
    runCellularFsmWithModem(NoOpThread, NoOpNotify, ModemT, &modem, TimeT, time, LogT, log);
}

/// `true` = stop (`error` or segment stuck past `step4_max_ticks_per_state`).
fn runCellularStateSegment(
    comptime LogT: type,
    logv: LogT,
    time: anytype,
    state_idx: u32,
    cell: anytype,
    prev_sim: *embed.pkg.cellular.types.SimStatus,
) bool {
    const expect = cellularPhaseForState(state_idx);
    var inner: u32 = 0;
    while (cell.phase() == expect) {
        inner += 1;
        if (inner > step4_max_ticks_per_state) {
            logv.infoFmt("{s} [STATE={d}/{d}] [WARN] max_ticks_per_state still phase={s}", .{
                step4_tag,
                state_idx,
                step4_state_total,
                @tagName(expect),
            });
            return true;
        }
        const at = atSentLabel(cell);
        cell.tick();
        logCellFsmLine(LogT, logv, at, cell, prev_sim);
        if (cell.phase() == .@"error") return true;
        const sleep_ms = if (state_idx == 4 and cell.bootstrapStep() == .done)
            step4_reg_poll_interval_ms
        else
            step4_sleep_between_ticks_ms;
        time.sleepMs(sleep_ms);
    }
    return cell.phase() == .@"error";
}

fn cellularPhaseForState(state_idx: u32) embed.pkg.cellular.types.CellularPhase {
    return switch (state_idx) {
        1 => .probing,
        2 => .at_configuring,
        3 => .checking_sim,
        4 => .registering,
        else => .off,
    };
}

/// Log label aligned with **current** `PHASE` (post-tick). Avoids e.g. `[STATE=2/4]` + `PHASE:checking_sim`.
fn cellFsmStateTag(ph: embed.pkg.cellular.types.CellularPhase) []const u8 {
    return switch (ph) {
        .probing => "1/4",
        .at_configuring => "2/4",
        .checking_sim => "3/4",
        .registering => "4/4",
        .registered => "registered",
        .@"error" => "error",
        else => "-",
    };
}

fn atSentLabel(cell: anytype) []const u8 {
    const ph = cell.phase();
    const st = cell.bootstrapStep();
    return switch (ph) {
        .probing => if (st == .probe) "AT" else "-",
        .at_configuring => switch (st) {
            .ate0 => "ATE0",
            .cmee => "AT+CMEE=2",
            else => "-",
        },
        .checking_sim => if (st == .cpin) "AT+CPIN?" else "-",
        .registering => "AT+CEREG?",
        else => "-",
    };
}

fn logCellFsmBoot(comptime LogT: type, logv: LogT, cell: anytype) void {
    const m = cell.modemState();
    logv.infoFmt("{s} [STATE=1/4] [PHASE:probing] sim={s} reg={s}", .{
        step4_tag,
        @tagName(m.sim),
        @tagName(m.registration),
    });
}

fn logCellFsmLine(
    comptime LogT: type,
    logv: LogT,
    at_sent: []const u8,
    cell: anytype,
    prev_sim: *embed.pkg.cellular.types.SimStatus,
) void {
    const m = cell.modemState();
    if (m.sim == .ready and prev_sim.* != .ready) {
        logv.infoFmt("{s} SIM OK！", .{step4_tag});
    }
    prev_sim.* = m.sim;
    const err_s: []const u8 = if (m.error_reason) |e| @tagName(e) else "-";
    logv.infoFmt("{s} [STATE={s}] {s} [PHASE:{s}] sim={s} reg={s} err={s}", .{
        step4_tag,
        cellFsmStateTag(cell.phase()),
        at_sent,
        @tagName(cell.phase()),
        @tagName(m.sim),
        @tagName(m.registration),
        err_s,
    });
}

fn logCellFsmFinale(comptime LogT: type, logv: LogT, cell: anytype) void {
    const ph = cell.phase();
    if (ph == .registered or ph == .@"error") {
        logv.infoFmt("{s} [PHASE:{s}] [STOP] terminal", .{ step4_tag, @tagName(ph) });
    } else {
        logv.infoFmt("{s} [PHASE:{s}] [WARN] bootstrap incomplete", .{ step4_tag, @tagName(ph) });
    }
    logv.infoFmt("{s} [DONE]", .{step4_tag});
}

fn queryAndLogIdentifiers(comptime LogT: type, logv: LogT, cell: anytype) void {
    logv.infoFmt("{s} [START] querying IMEI/IMSI/ICCID", .{step5_tag});

    if (cell.modem.getImei()) |imei| {
        logv.infoFmt("{s} IMEI={s}", .{ step5_tag, imei });
    } else |e| {
        logv.infoFmt("{s} [WARN] IMEI query failed: {s}", .{ step5_tag, @errorName(e) });
    }

    if (cell.modem.getImsi()) |imsi| {
        logv.infoFmt("{s} IMSI={s}", .{ step5_tag, imsi });
    } else |e| {
        logv.infoFmt("{s} [WARN] IMSI query failed: {s}", .{ step5_tag, @errorName(e) });
    }

    if (cell.modem.getIccid()) |iccid| {
        logv.infoFmt("{s} ICCID={s}", .{ step5_tag, iccid });
    } else |e| {
        logv.infoFmt("{s} [WARN] ICCID query failed: {s}", .{ step5_tag, @errorName(e) });
    }

    logv.infoFmt("{s} [DONE]", .{step5_tag});
}

fn mockFeedForBootstrapTick(mock: *mock_mod.MockIo, cell: anytype) void {
    switch (cell.bootstrapStep()) {
        .probe => mock.feed("OK\r\n"),
        .ate0 => mock.feed("OK\r\n"),
        .cmee => mock.feed("OK\r\n"),
        .cpin => mock.feed("\r\n+CPIN: READY\r\n\r\nOK\r\n"),
        .cereg => mock.feed("\r\n+CEREG: 0,1\r\n\r\nOK\r\n"),
        .done => {
            if (cell.phase() == .registering and cell.bootstrapStep() == .done)
                mock.feed("\r\n+CEREG: 0,1\r\n\r\nOK\r\n");
        },
    }
}

fn runMockCellularStateSegment(
    comptime LogT: type,
    logv: LogT,
    mock: *mock_mod.MockIo,
    state_idx: u32,
    cell: anytype,
    prev_sim: *embed.pkg.cellular.types.SimStatus,
) bool {
    const expect = cellularPhaseForState(state_idx);
    var inner: u32 = 0;
    while (cell.phase() == expect) {
        inner += 1;
        if (inner > step4_max_ticks_per_state) {
            logv.infoFmt("{s} [STATE={d}/{d}] [WARN] max_ticks_per_state mock", .{ step4_tag, state_idx, step4_state_total });
            return true;
        }
        const at = atSentLabel(cell);
        mockFeedForBootstrapTick(mock, cell);
        cell.tick();
        logCellFsmLine(LogT, logv, at, cell, prev_sim);
        if (cell.phase() == .@"error") return true;
    }
    return cell.phase() == .@"error";
}

/// Last Step4 terminal phase after mock run (for `test "run with mock hw"`).
var g_step4_final_phase_state: embed.pkg.cellular.types.CellularPhase = .off;

/// Mock Step4: fresh MockIo + feed before each tick (same sequence as `cellular_test.zig` bootstrap to registered).
fn runCellularFsmMock(
    mock: *mock_mod.MockIo,
    comptime TimeT: type,
    time: TimeT,
    comptime LogT: type,
    log: LogT,
) void {
    const cellular_mod = embed.pkg.cellular.cellular_mod;
    const modem_mod = embed.pkg.cellular.modem.modem_mod;
    const bus = embed.pkg.event.bus;
    const types = embed.pkg.cellular.types;
    const quectel = embed.pkg.cellular.modem.profiles.quectel;

    mock.* = mock_mod.MockIo.init();
    const io = io_mod.fromUart(mock_mod.MockIo, mock);

    const quectel_stub = embed.pkg.cellular.modem.profiles.quectel_stub;
    const ModemStubT = modem_mod.Modem(NoOpThread, NoOpNotify, TimeT, quectel_stub, GpioPh, 1024);
    var modem_stub = ModemStubT.init(.{ .io = io, .time = time, .gpio = null }) catch @panic("Step8 stub init");
    log.infoFmt("{s} === Modem routing test ===", .{step8_tag});
    log.infoFmt("{s} Modem mode: {s}", .{ step8_tag, @tagName(modem_stub.mode()) });
    mock.feed("OK\r\n");
    const modem_routing_timeout_ms: u32 = 5000;
    const r = modem_stub.at().sendRaw("AT\r\n", modem_routing_timeout_ms);
    log.infoFmt("{s} modem.at().sendRaw(\"AT\\r\\n\") -> status={s}", .{ step8_tag, @tagName(r.status) });
    if (modem_stub.pppIo() == null) {
        log.infoFmt("{s} modem.pppIo() = null (CMUX not active yet, expected)", .{step8_tag});
    }

    const ModemT = modem_mod.Modem(NoOpThread, NoOpNotify, TimeT, quectel, GpioPh, 1024);
    const CellularT = cellular_mod.Cellular(NoOpThread, NoOpNotify, TimeT, quectel, GpioPh, 1024);

    const injector = bus.EventInjector(types.CellularPayload){
        .ctx = null,
        .call = struct {
            fn f(_: ?*anyopaque, _: types.CellularPayload) void {}
        }.f,
    };

    const modem = ModemT.init(.{ .io = io, .time = time, .gpio = null }) catch @panic("Modem init");
    var cell = CellularT.init(modem, injector);

    log.infoFmt("{s} [START] mock bootstrap + EPS", .{step4_tag});
    cell.powerOn();
    var prev_sim: embed.pkg.cellular.types.SimStatus = .not_inserted;
    logCellFsmBoot(LogT, log, &cell);

    if (runMockCellularStateSegment(LogT, log, mock, 1, &cell, &prev_sim)) {
        g_step4_final_phase_state = cell.phase();
        logCellFsmFinale(LogT, log, &cell);
        return;
    }
    if (runMockCellularStateSegment(LogT, log, mock, 2, &cell, &prev_sim)) {
        g_step4_final_phase_state = cell.phase();
        logCellFsmFinale(LogT, log, &cell);
        return;
    }
    if (runMockCellularStateSegment(LogT, log, mock, 3, &cell, &prev_sim)) {
        g_step4_final_phase_state = cell.phase();
        logCellFsmFinale(LogT, log, &cell);
        return;
    }
    if (runMockCellularStateSegment(LogT, log, mock, 4, &cell, &prev_sim)) {
        g_step4_final_phase_state = cell.phase();
        logCellFsmFinale(LogT, log, &cell);
        return;
    }

    if (cell.phase() == .registered) {
        log.infoFmt("{s} EPS registered!", .{step4_tag});
    }
    g_step4_final_phase_state = cell.phase();
    logCellFsmFinale(LogT, log, &cell);

    if (cell.phase() == .registered) {
        log.infoFmt("{s} [START] querying IMEI/IMSI/ICCID", .{step5_tag});

        mock.feed("867456789012345\r\nOK\r\n");
        if (cell.modem.getImei()) |imei| {
            log.infoFmt("{s} IMEI={s}", .{ step5_tag, imei });
        } else |e| {
            log.infoFmt("{s} [WARN] IMEI query failed: {s}", .{ step5_tag, @errorName(e) });
        }

        mock.feed("460011234567890\r\nOK\r\n");
        if (cell.modem.getImsi()) |imsi| {
            log.infoFmt("{s} IMSI={s}", .{ step5_tag, imsi });
        } else |e| {
            log.infoFmt("{s} [WARN] IMSI query failed: {s}", .{ step5_tag, @errorName(e) });
        }

        mock.feed("+CCID: 89861234567890123456\r\nOK\r\n");
        if (cell.modem.getIccid()) |iccid| {
            log.infoFmt("{s} ICCID={s}", .{ step5_tag, iccid });
        } else |e| {
            log.infoFmt("{s} [WARN] ICCID query failed: {s}", .{ step5_tag, @errorName(e) });
        }

        log.infoFmt("{s} [DONE]", .{step5_tag});
    }
}

fn elapsedMs(time: anytype, t_start: u64) u64 {
    return time.nowMs() -| t_start;
}

/// Strip trailing CR/LF for log (e.g. "AT+CREG?\r\n" -> "AT+CREG?").
fn atCmdStripCrlf(cmd: []const u8) []const u8 {
    var end = cmd.len;
    while (end > 0 and (cmd[end - 1] == '\r' or cmd[end - 1] == '\n')) end -= 1;
    return cmd[0..end];
}

/// Fold whitespace to single spaces so [RECV] stays one line.
fn foldWs(out: []u8, raw: []const u8) []const u8 {
    var w: usize = 0;
    var prev_space = true;
    for (raw) |c| {
        const is_ws = c == '\r' or c == '\n' or c == '\t';
        if (is_ws) {
            if (!prev_space and w < out.len) {
                out[w] = ' ';
                w += 1;
                prev_space = true;
            }
        } else {
            if (w < out.len) {
                out[w] = c;
                w += 1;
                prev_space = false;
            }
        }
    }
    while (w > 0 and out[w - 1] == ' ') w -= 1;
    return out[0..w];
}

fn testParseAt(io: io_mod.Io, time: anytype, log: anytype, cmd: []const u8) void {
    log.infoFmt("{s} [SEND] {s}", .{ step3_tag, atCmdStripCrlf(cmd) });
    const t0 = time.nowMs();

    _ = io.write(cmd) catch |e| {
        log.infoFmt("{s} [ERROR] write:{s} ({d}ms)", .{ step3_tag, @errorName(e), elapsedMs(time, t0) });
        return;
    };
    time.sleepMs(500);

    const n = io.read(&g_cellular_rx) catch |e| {
        log.infoFmt("{s} [ERROR] read:{s} ({d}ms)", .{ step3_tag, @errorName(e), elapsedMs(time, t0) });
        return;
    };
    const ms = elapsedMs(time, t0);
    const body = foldWs(&g_cellular_fold, g_cellular_rx[0..n]);

    const summary = parseSummary(cmd, g_cellular_rx[0..n]);
    if (summary.len > 0) {
        log.infoFmt("{s} [RECV] {s} | {s} ({d}ms)", .{ step3_tag, body, summary, ms });
    } else {
        log.infoFmt("{s} [RECV] {s} ({d}ms)", .{ step3_tag, body, ms });
    }
}

/// Short parse hint for RECV line; empty if nothing extra beyond raw body.
fn parseSummary(cmd: []const u8, raw: []const u8) []const u8 {
    const c = atCmdStripCrlf(cmd);
    if (std.mem.eql(u8, c, "AT+CSQ")) {
        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |line| {
            if (parse.parsePrefix(line, "+CSQ:")) |val| {
                if (parse.parseCsq(val)) |sig| {
                    const s = if (sig.ber) |ber|
                        std.fmt.bufPrint(&g_parse_summary, "parse:csq rssi={d}dBm ber={d} pct={d}", .{
                            sig.rssi, ber, parse.rssiToPercent(sig.rssi),
                        })
                    else
                        std.fmt.bufPrint(&g_parse_summary, "parse:csq rssi={d}dBm ber=n/a pct={d}", .{
                            sig.rssi, parse.rssiToPercent(sig.rssi),
                        });
                    return s catch return "parse:csq";
                }
                return "parse:csq rssi=unknown(99?)";
            }
        }
        return "";
    }
    if (std.mem.eql(u8, c, "AT+CPIN?")) {
        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |line| {
            if (parse.parseCmeError(line)) |code| {
                const s = std.fmt.bufPrint(&g_parse_summary, "parse:cpin CME={d}", .{code}) catch return "parse:cpin CME";
                return s;
            }
            if (parse.parseCmsError(line)) |code| {
                const s = std.fmt.bufPrint(&g_parse_summary, "parse:cpin CMS={d}", .{code}) catch return "parse:cpin CMS";
                return s;
            }
            if (parse.parsePrefix(line, "+CPIN:")) |val| {
                if (parse.parseCpin(val)) |st| {
                    return @as([]const u8, switch (st) {
                        .ready => "parse:cpin READY",
                        .pin_required => "parse:cpin PIN",
                        .puk_required => "parse:cpin PUK",
                        .not_inserted => "parse:cpin no_sim",
                        .@"error" => "parse:cpin SIM_ERR",
                    });
                }
                return "parse:cpin unrecognized +CPIN value";
            }
        }
        return "";
    }
    if (std.mem.eql(u8, c, "AT+CREG?") or std.mem.eql(u8, c, "AT+CGREG?") or std.mem.eql(u8, c, "AT+CEREG?")) {
        const pfx: []const u8 = if (std.mem.eql(u8, c, "AT+CREG?"))
            "+CREG:"
        else if (std.mem.eql(u8, c, "AT+CGREG?"))
            "+CGREG:"
        else
            "+CEREG:";
        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |line| {
            if (parse.parsePrefix(line, pfx)) |val| {
                if (parse.parseCreg(val)) |reg| {
                    const kind: []const u8 = if (std.mem.eql(u8, pfx, "+CEREG:")) "eps" else "gsm";
                    const s = std.fmt.bufPrint(&g_parse_summary, "parse:reg_{s} {s}", .{ kind, @tagName(reg) }) catch return "parse:reg";
                    return s;
                }
                return "parse:reg bad_stat";
            }
        }
        return "";
    }
    return "";
}

const mock_mod = embed.pkg.cellular.io.mock;

var test_mock_io: mock_mod.MockIo = mock_mod.MockIo.init();

test "run with mock hw" {
    test_mock_io = mock_mod.MockIo.init();
    test_mock_io.feed("OK\r\n");

    const MockHw = struct {
        pub const name: []const u8 = "mock_cellular";

        pub fn init() !void {}
        pub fn deinit() void {}

        pub const rtc_spec = struct {
            pub const Driver = struct {
                pub fn init() !@This() {
                    return .{};
                }
                pub fn deinit(_: *@This()) void {}
                pub fn uptime(_: *@This()) u64 {
                    return 0;
                }
                pub fn nowMs(_: *@This()) ?i64 {
                    return null;
                }
            };
            pub const meta = .{ .id = "rtc.mock" };
        };

        pub const log = struct {
            pub fn debug(_: @This(), _: []const u8) void {}
            pub fn info(_: @This(), _: []const u8) void {}
            pub fn warn(_: @This(), _: []const u8) void {}
            pub fn err(_: @This(), _: []const u8) void {}
        };

        pub const time = struct {
            pub fn nowMs(_: @This()) u64 {
                return 0;
            }
            pub fn sleepMs(_: @This(), _: u32) void {}
        };

        pub fn uart_cellular() *mock_mod.MockIo {
            return &test_mock_io;
        }
    };
    run(MockHw, .{});
    try std.testing.expectEqual(embed.pkg.cellular.types.CellularPhase.registered, g_step4_final_phase_state);
}
