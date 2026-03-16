//! Board specification for 106-lcd-hello-world.
//!
//! Required from `hw`:
//!   - name: []const u8
//!   - rtc_spec: struct { Driver, meta }
//!   - display_spec: struct { Driver, meta }
//!   - log:  scoped logger
//!   - time: struct { nowMs, sleepMs }

const embed = @import("embed");
const hal = embed.hal;
const runtime = embed.runtime;

pub fn Board(comptime hw: type) type {
    const spec = struct {
        pub const meta = .{ .id = hw.name };

        pub const log = runtime.log.Log(hw.log);
        pub const time = runtime.time.Time(hw.time);
        pub const allocator = if (@hasDecl(hw, "allocator")) hw.allocator else void;
        pub const fs = if (@hasDecl(hw, "fs")) runtime.fs.from(hw.fs) else void;

        pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
        pub const display = hal.display.from(hw.display_spec);
    };
    return hal.board.Board(spec);
}
