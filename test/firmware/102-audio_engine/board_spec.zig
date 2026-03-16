//! Board specification for 102-audio_engine.
//!
//! Required from `hw`:
//!   - name, allocator, thread, sync, log, time, io
//!   - rtc_spec, adc_spec, audio_system_spec
//!   - adc_button_config: event.button.AdcButtonConfig

const std = @import("std");
const embed = @import("embed");
const hal = embed.hal;
const runtime = embed.runtime;
const event = embed.pkg.event;

const required_buttons = [_][]const u8{ "play", "set", "vol_up", "vol_down", "mute" };

fn validateButtonRanges(comptime cfg: event.button.AdcButtonConfig) void {
    for (required_buttons) |name| {
        var found = false;
        for (cfg.ranges) |r| {
            if (std.mem.eql(u8, r.id, name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            @compileError("adc_button_config missing required button: " ++ name);
        }
    }
}

pub fn Board(comptime hw: type) type {
    comptime validateButtonRanges(hw.adc_button_config);

    const spec = struct {
        pub const meta = .{ .id = hw.name };
        pub const log = runtime.log.Log(hw.log);
        pub const time = runtime.time.Time(hw.time);
        pub const channel = hw.channel;

        pub const thread = struct {
            pub const Type = runtime.thread.Thread(hw.thread.Thread);
            pub const user = hw.thread.user_defaults;
            pub const system = hw.thread.system_defaults;
            pub const default = hw.thread.default_defaults;
        };

        pub const allocator = struct {
            pub const user = hw.allocator.user;
            pub const system = hw.allocator.system;
            pub const default = hw.allocator.default;
        };

        pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
        pub const adc = hal.adc.from(hw.adc_spec);
        pub const audio_system = hal.audio_system.from(hw.audio_system_spec);
    };

    const HalBoard = hal.board.Board(spec);

    return struct {
        pub const meta = HalBoard.meta;
        pub const log = HalBoard.log;
        pub const time = HalBoard.time;
        pub const channel = HalBoard.channel;
        pub const thread = HalBoard.thread;
        pub const allocator = HalBoard.allocator;
        pub const isRunning = HalBoard.isRunning;
        pub const adc = HalBoard.adc;
        pub const audio_system = HalBoard.audio_system;
        pub const adc_button_config = hw.adc_button_config;

        hal_board: HalBoard,

        pub fn init(self: *@This()) !void {
            try self.hal_board.init();
        }

        pub fn deinit(self: *@This()) void {
            self.hal_board.deinit();
        }
    };
}
