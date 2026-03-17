//! 110-cellular firmware — Step 2: Io interface (fromUart) verification.
//!
//! 1. Wrap UART via io.fromUart(), send "AT\r\n", wait 500 ms, read response, log.
//! 2. Pass: Io.write() returns 4; read content contains "OK" (when modem connected).

const board_spec = @import("board_spec.zig");
const esp = @import("esp");
const embed = esp.embed;
const io_mod = embed.pkg.cellular.io.io_mod;

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
