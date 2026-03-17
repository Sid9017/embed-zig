//! 110-cellular firmware — Step 2 + Step 3 verification.
//!
//! Step 2: Io interface — send AT, read response.
//! Step 3: parse — send AT+CSQ/AT+CPIN?/AT+CREG?, parse real modem responses.

const board_spec = @import("board_spec.zig");
const esp = @import("esp");
const embed = esp.embed;
const io_mod = embed.pkg.cellular.io.io_mod;
const parse = embed.pkg.cellular.at.parse;

pub fn run(comptime hw: type, env: anytype) void {
    _ = env;

    const Board = board_spec.Board(hw);
    const log: Board.log = .{};
    const time: Board.time = .{};

    hw.init() catch {
        log.err("hw init failed");
        return;
    };
    defer hw.deinit();

    log.info("cellular test ready");

    const uart_ptr = hw.uart_cellular();
    const UartType = @TypeOf(uart_ptr.*);
    const io = io_mod.fromUart(UartType, uart_ptr);

    log.info("=== Step 2: Io interface test ===");

    log.infoFmt("t={d}ms waiting 3s for modem power-up...", .{time.nowMs()});
    time.sleepMs(3000);
    log.infoFmt("t={d}ms power-up done", .{time.nowMs()});

    const cmd = "AT\r\n";
    const n_write = io.write(cmd) catch |e| {
        log.errFmt("Io.write failed: {s}", .{@errorName(e)});
        return;
    };
    log.infoFmt("Io.write(\"AT\\r\\n\") sent {d} bytes", .{n_write});

    time.sleepMs(500);

    var buf: [256]u8 = undefined;
    const n_read = io.read(&buf) catch |e| {
        switch (e) {
            io_mod.IoError.WouldBlock => log.info("Io.read() got 0 bytes (WouldBlock)"),
            else => log.errFmt("Io.read error: {s}", .{@errorName(e)}),
        }
        log.info("Step 2 Io test done");
        return;
    };
    const slice = buf[0..n_read];
    log.infoFmt("Io.read() got {d} bytes: {s}", .{ n_read, slice });

    log.info("Step 2 Io test done");

    // === Step 3: parse real-device test ===
    log.info("=== Step 3: parse real-device test ===");

    testAtCommand(io, time, log, "AT+CSQ\r\n", "CSQ");
    testAtCommand(io, time, log, "AT+CPIN?\r\n", "CPIN");
    testAtCommand(io, time, log, "AT+CREG?\r\n", "CREG");
    testAtCommand(io, time, log, "AT+CGREG?\r\n", "CGREG");

    log.info("Step 3 parse test done");
}

fn testAtCommand(io: io_mod.Io, time: anytype, log: anytype, cmd: []const u8, comptime label: []const u8) void {
    const t_start = time.nowMs();
    const n_write = io.write(cmd) catch |e| {
        log.errFmt("[" ++ label ++ "] write failed: {s}", .{@errorName(e)});
        return;
    };
    _ = n_write;
    time.sleepMs(500);

    var buf: [512]u8 = undefined;
    const n_read = io.read(&buf) catch |e| {
        const elapsed = time.nowMs() -| t_start;
        switch (e) {
            io_mod.IoError.WouldBlock => log.infoFmt("[" ++ label ++ "] no response (WouldBlock) {d}ms", .{elapsed}),
            else => log.errFmt("[" ++ label ++ "] read error: {s} {d}ms", .{ @errorName(e), elapsed }),
        }
        return;
    };
    const elapsed = time.nowMs() -| t_start;
    const raw = buf[0..n_read];
    log.infoFmt("[" ++ label ++ "] raw ({d} bytes, {d}ms): {s}", .{ n_read, elapsed, raw });

    // Parse each line of the response
    var line_iter = std.mem.splitScalar(u8, raw, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        if (parse.isOk(line)) {
            log.info("[" ++ label ++ "] -> OK");
            continue;
        }
        if (parse.isError(line)) {
            log.info("[" ++ label ++ "] -> ERROR");
            continue;
        }
        if (parse.parseCmeError(line)) |code| {
            log.infoFmt("[" ++ label ++ "] -> CME ERROR: {d}", .{code});
            continue;
        }

        if (comptime std.mem.eql(u8, label, "CSQ")) {
            if (parse.parsePrefix(line, "+CSQ:")) |val| {
                log.infoFmt("[CSQ] parsePrefix -> \"{s}\"", .{val});
                if (parse.parseCsq(val)) |sig| {
                    log.infoFmt("[CSQ] rssi={d} dBm, ber={s}, percent={d}%", .{
                        sig.rssi,
                        if (sig.ber) |b| &[_]u8{'0' + b} else "n/a",
                        parse.rssiToPercent(sig.rssi),
                    });
                } else {
                    log.info("[CSQ] parseCsq returned null (no signal?)");
                }
            }
        }

        if (comptime std.mem.eql(u8, label, "CPIN")) {
            if (parse.parsePrefix(line, "+CPIN:")) |val| {
                log.infoFmt("[CPIN] parsePrefix -> \"{s}\"", .{val});
                if (parse.parseCpin(val)) |status| {
                    log.infoFmt("[CPIN] SimStatus -> {s}", .{@tagName(status)});
                } else {
                    log.infoFmt("[CPIN] parseCpin returned null for \"{s}\"", .{val});
                }
            }
        }

        if (comptime std.mem.eql(u8, label, "CREG") or std.mem.eql(u8, label, "CGREG")) {
            const prefix = if (comptime std.mem.eql(u8, label, "CREG")) "+CREG:" else "+CGREG:";
            if (parse.parsePrefix(line, prefix)) |val| {
                log.infoFmt("[" ++ label ++ "] parsePrefix -> \"{s}\"", .{val});
                if (parse.parseCreg(val)) |reg| {
                    log.infoFmt("[" ++ label ++ "] RegStatus -> {s}", .{@tagName(reg)});
                } else {
                    log.infoFmt("[" ++ label ++ "] parseCreg returned null for \"{s}\"", .{val});
                }
            }
        }
    }
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
