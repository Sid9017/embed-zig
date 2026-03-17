//! BSP for 110-cellular on ESP32-S3 DevKit.
//! Provides log, time, rtc_spec, uart_cellular (stub adapter for Step 2).
//! Replace stub with real UART (4G modem pins, 115200) for burn-in.

const esp_rt = @import("esp").runtime;
const esp_hal = @import("esp").hal;
const esp_rom = @import("esp").component.esp_rom;
const embed = @import("esp").embed;
const io_mod = embed.pkg.cellular.io.io_mod;

pub const name: []const u8 = "esp32s3_devkit";

pub fn init() !void {}
pub fn deinit() void {}

pub const rtc_spec = struct {
    pub const Driver = esp_hal.RtcReader.DriverType;
    pub const meta = .{ .id = "rtc.devkit" };
};

fn printMsg(prefix: [*:0]const u8, msg: []const u8) void {
    esp_rom.printf("%s", .{prefix});
    for (msg) |c| esp_rom.printf("%c", .{c});
    esp_rom.printf("\n", .{});
}

pub const log = struct {
    pub fn debug(_: @This(), msg: []const u8) void {
        printMsg("[D] ", msg);
    }
    pub fn info(_: @This(), msg: []const u8) void {
        printMsg("[I] ", msg);
    }
    pub fn warn(_: @This(), msg: []const u8) void {
        printMsg("[W] ", msg);
    }
    pub fn err(_: @This(), msg: []const u8) void {
        printMsg("[E] ", msg);
    }
};

pub const time = esp_rt.Time;

/// Stub UART adapter for pkg/cellular/io fromUart contract. Read returns WouldBlock;
/// write accepts bytes; poll returns no readable. Replace with real HAL UART wrapper for burn-in.
const StubCellularUart = struct {
    pub fn read(_: *@This(), _: []u8) io_mod.IoError!usize {
        return error.WouldBlock;
    }
    pub fn write(_: *@This(), buf: []const u8) io_mod.IoError!usize {
        return buf.len;
    }
    pub fn poll(_: *@This(), _: i32) io_mod.PollFlags {
        return .{};
    }
};

var stub_uart: StubCellularUart = .{};

pub fn uart_cellular() *StubCellularUart {
    return &stub_uart;
}
