//! Board specification for 100-button_led_cycle.
//!
//! Declares the HAL peripherals and runtime capabilities this firmware
//! requires. Platform shims (esp, websim, etc.) provide a `hw` module
//! that satisfies these requirements; this file wires them into a
//! concrete Board type via `hal.Board(spec)`.
//!
//! Required from `hw`:
//!   - name: []const u8
//!   - allocator: struct { user, system, default: std.mem.Allocator }
//!   - thread:    struct { user, system: Thread impl }
//!   - rtc_spec: struct { Driver, meta }
//!   - led_strip_spec: struct { Driver, meta }
//!   - gpio_spec: struct { Driver, meta }
//!   - log:  struct { debug, info, warn, err }
//!   - time: struct { nowMs, sleepMs }

const embed = @import("embed");
const hal = embed.hal;
const runtime = embed.runtime;

pub fn Board(comptime hw: type) type {
    const spec = struct {
        pub const meta = .{ .id = hw.name };

        pub const log = runtime.log.Log(hw.log);
        pub const time = runtime.time.Time(hw.time);
        pub const channel = hw.channel;

        pub const thread = struct {
            pub const user = runtime.thread.Thread(hw.thread.user);
            pub const system = runtime.thread.Thread(hw.thread.system);
            pub const default = runtime.thread.Thread(hw.thread.default);
        };

        pub const allocator = struct {
            pub const user = hw.allocator.user;
            pub const system = hw.allocator.system;
            pub const default = hw.allocator.default;
        };

        pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
        pub const led_strip = hal.led_strip.from(hw.led_strip_spec);
        pub const gpio = hal.gpio.from(hw.gpio_spec);
    };
    return hal.board.Board(spec);
}

pub const LedColor = struct {
    on: bool,
    r: u8,
    g: u8,
    b: u8,

    pub const black = LedColor{ .on = false, .r = 0, .g = 0, .b = 0 };
    pub const white = LedColor{ .on = true, .r = 255, .g = 255, .b = 255 };
    pub const red = LedColor{ .on = true, .r = 255, .g = 0, .b = 0 };
    pub const green = LedColor{ .on = true, .r = 0, .g = 255, .b = 0 };
    pub const blue = LedColor{ .on = true, .r = 0, .g = 0, .b = 255 };
};
