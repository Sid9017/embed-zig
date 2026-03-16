//! Board specification for 101-hello_world.
//!
//! Declares the HAL peripherals and runtime capabilities this firmware
//! requires. Platform shims (esp, websim, etc.) provide a `hw` module
//! that satisfies these requirements; this file wires them into a
//! concrete Board type via `hal.Board(spec)`.
//!
//! Required from `hw`:
//!   - name: []const u8
//!   - rtc_spec: struct { Driver, meta }
//!   - log:  scoped logger (comptime fmt)
//!   - time: struct { nowMs, sleepMs }

const embed = @import("esp").embed;
const hal = embed.hal;
const runtime = embed.runtime;

pub fn Board(comptime hw: type) type {
    const spec = struct {
        pub const meta = .{ .id = hw.name };

        // --- runtime primitives ---
        pub const log = runtime.log.Make(hw.log);
        pub const time = runtime.time.Make(hw.time);

        // --- HAL peripherals ---
        pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    };
    return hal.board.Board(spec);
}
