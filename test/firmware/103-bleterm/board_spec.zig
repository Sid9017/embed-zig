//! Board specification for 103-bleterm.
//!
//! Declares the HAL peripherals and runtime capabilities this firmware
//! requires for BLE Term operation.
//!
//! Required from `hw`:
//!   - name: []const u8
//!   - allocator: struct { user, system, default: std.mem.Allocator }
//!   - thread:    struct { Thread, user_defaults, system_defaults }
//!   - sync:      struct { Mutex, Condition }
//!   - log:  struct { debug, info, warn, err }
//!   - time: struct { nowMs, sleepMs }
//!   - rtc_spec: struct { Driver, meta }

const embed = @import("esp").embed;
const hal = embed.hal;
const runtime = embed.runtime;

pub fn Board(comptime hw: type) type {
    const spec = struct {
        pub const meta = .{ .id = hw.name };

        pub const log = runtime.log.Make(hw.log);
        pub const time = runtime.time.Make(hw.time);

        pub const thread = struct {
            pub const Type = runtime.thread.Make(hw.thread.Thread);
            pub const user = hw.thread.user_defaults;
            pub const system = hw.thread.system_defaults;
        };

        pub const allocator = struct {
            pub const user = hw.allocator.user;
            pub const system = hw.allocator.system;
        };

        pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    };
    return hal.board.Board(spec);
}
