//! Board specification for 110-cellular.
//!
//! Declares HAL and runtime capabilities. Platform (e.g. test/esp/110-cellular or
//! esp-zig/examples/cellular) provides `hw` satisfying: name, init, deinit, log,
//! time, rtc_spec, uart_cellular.
//!
//! Required from `hw`:
//!   - uart_cellular() *T where T has read(*T, []u8) IoError!usize,
//!     write(*T, []const u8) IoError!usize, poll(*T, i32) PollFlags
//!     (pkg/cellular/io contract for fromUart).
//!
//! Pin numbers (UART TX/RX/RTS/CTS, modem power, DTR) are not defined here;
//! they are configured in the platform BSP (e.g. board/esp32s3_devkit/bsp.zig).

const embed = @import("esp").embed;
const hal = embed.hal;
const runtime = embed.runtime;

pub fn Board(comptime hw: type) type {
    const spec = struct {
        pub const meta = .{ .id = hw.name };

        pub const log = runtime.log.Make(hw.log);
        pub const time = runtime.time.Make(hw.time);
        pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    };
    return hal.board.Board(spec);
}
