//! 110-cellular firmware — Step 0 + Step 2 + Step 3 burn-in + Step 4 Cellular FSM (UART or mock scripted).
//!
//! Step 0: UART/modem power path ready (cellular_dev § Step 0).
//! Step 2: Io — send AT, read response.
//! Step 3: parse — CSQ, CPIN, CREG, CGREG, CEREG (+ CME/CMS/unrecognized CPIN summaries).
//! Step 4: `powerOn` then four bootstrap segments — within each segment, `tick()` until the next `CellularPhase`
//! or `error`. Tags `[STATE=1/4]`…`[STATE=4/4]` match `probing` → `at_configuring` → `checking_sim` → `registering`.

const board_spec = @import("board_spec.zig");
const esp = @import("esp");
const embed = esp.embed;
const io_mod = embed.pkg.cellular.io.io_mod;
const parse = embed.pkg.cellular.at.parse;
const std = @import("std");

const step0_tag = "[step0-uartSetup]";
const step2_tag = "[step2-ioTest]";
const step3_tag = "[step3-parseTest]";
const step4_tag = "[step4-cellFsm]";
const step5_tag = "[step5-identity]";
/// Bootstrap segments: probing, at_configuring, checking_sim, registering.
const step4_state_total: u32 = 4;
/// Safety cap per segment (in case the modem never advances).
const step4_max_ticks_per_state: u32 = 400;
const step4_sleep_between_ticks_ms: u32 = 20;
/// Longer sleep between ticks while `registering` and `bootstrap_step == .done` (post–first CEREG, still searching).
const step4_reg_poll_interval_ms: u32 = 3000;

/// Main-thread only. Large on-stack RX/fold buffers exhaust ESP-IDF main task stack (~3584 B)
/// when combined with fmt/log frames; use BSS instead.
var g_cellular_rx: [384]u8 = undefined;
var g_cellular_fold: [384]u8 = undefined;
/// parseSummary must not return slices into stack locals (dangling); main-thread only.
var g_parse_summary: [96]u8 = undefined;

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

    time.sleepMs(3000);

    // Step 2: single AT probe
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

    // Step 3: typed AT + parse (parse outcome appended to RECV line when useful)
    testParseAt(io, time, log, "AT+CSQ\r\n");
    testParseAt(io, time, log, "AT+CPIN?\r\n");
    testParseAt(io, time, log, "AT+CREG?\r\n");
    testParseAt(io, time, log, "AT+CGREG?\r\n");
    testParseAt(io, time, log, "AT+CEREG?\r\n");

    log.infoFmt("{s} [DONE] step3 parse tests finished", .{step3_tag});

    if (comptime isMockCellularHw(hw)) {
        runCellularFsmMock(uart_ptr, Board.time, time, Board.log, log);
        return;
    }

    time.sleepMs(500);
    runCellularFsm(io, Board.time, time, Board.log, log);
}

/// True for the unit-test mock board (`zig build test-110-cellular-firmware`).
fn isMockCellularHw(comptime hw: type) bool {
    return std.mem.eql(u8, hw.name, "mock_cellular");
}

/// Drive `Cellular` bootstrap: per `[STATE=N/4]`, tick until leaving that phase or `error`.
fn runCellularFsm(
    io: io_mod.Io,
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

    const GpioPh = struct {};
    const ModemT = modem_mod.Modem(struct {}, struct {}, TimeT, quectel, GpioPh, 1024);
    const CellularT = cellular_mod.Cellular(struct {}, struct {}, TimeT, quectel, GpioPh, 1024);

    const injector = bus.EventInjector(types.CellularPayload){
        .ctx = null,
        .call = struct {
            fn f(_: ?*anyopaque, _: types.CellularPayload) void {}
        }.f,
    };

    const modem = ModemT.init(.{ .io = io, .time = time, .gpio = null });
    var cell = CellularT.init(modem, injector);

    log.infoFmt("{s} [START] bootstrap + EPS poll until registered", .{step4_tag});
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

    const GpioPh = struct {};
    const ModemT = modem_mod.Modem(struct {}, struct {}, TimeT, quectel, GpioPh, 1024);
    const CellularT = cellular_mod.Cellular(struct {}, struct {}, TimeT, quectel, GpioPh, 1024);

    const injector = bus.EventInjector(types.CellularPayload){
        .ctx = null,
        .call = struct {
            fn f(_: ?*anyopaque, _: types.CellularPayload) void {}
        }.f,
    };

    const modem = ModemT.init(.{ .io = io, .time = time, .gpio = null });
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
