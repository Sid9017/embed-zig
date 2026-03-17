const inner = @import("board/esp32s3_devkit/bsp.zig");

pub const name = inner.name;
pub const init = inner.init;
pub const deinit = inner.deinit;
pub const rtc_spec = inner.rtc_spec;
pub const log = inner.log;
pub const time = inner.time;
pub const uart_cellular = inner.uart_cellular;
