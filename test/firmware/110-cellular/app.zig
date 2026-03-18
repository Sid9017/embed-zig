//! 110-cellular firmware — Step 0 + Step 2 + Step 3 burn-in checks.
//!
//! Step 0: UART/modem power path ready (cellular_dev § Step 0).
//! Step 2: Io — send AT, read response.
//! Step 3: parse — CSQ, CPIN, CREG, CGREG, CEREG (+ CME/CMS/unrecognized CPIN summaries).
//! Still device-dependent (no SIM → no +CPIN READY / roaming, etc.); full matrix in test/unit/pkg/cellular/at/parse_test.zig.

const board_spec = @import("board_spec.zig");
const esp = @import("esp");
const embed = esp.embed;
const io_mod = embed.pkg.cellular.io.io_mod;
const parse = embed.pkg.cellular.at.parse;

const step0_tag = "[step0-uartSetup]";
const step2_tag = "[step2-ioTest]";
const step3_tag = "[step3-parseTest]";

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

const std = @import("std");
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
}
