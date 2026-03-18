//! ADC Button — multi-button input via single ADC channel.
//!
//! Polls an ADC channel through a blocking loop. Multiple buttons share
//! one channel via a resistor ladder; each button maps to a voltage range.
//!
//! Only emits press/release events. When the voltage jumps from one button
//! range to another without returning to ref, a release for the old button
//! and a press for the new button are emitted back-to-back.
//!
//! The caller is responsible for running the polling loop. Call `run()`
//! from a dedicated thread/task; call `requestStop()` to exit the loop.

const std = @import("std");
const embed = @import("../../../../mod.zig");
const bus_mod = embed.pkg.event.bus;
const button_event = embed.pkg.event.button.events;

const Event = button_event.RawEvent;
const Code = button_event.RawEventCode;
const Injector = bus_mod.EventInjector(Event);

pub const Range = struct {
    id: []const u8,
    min_mv: u16,
    max_mv: u16,
};

pub const Config = struct {
    ranges: []const Range,
    adc_channel: u8 = 0,
    ref_value_mv: u32 = 3300,
    ref_tolerance_mv: u32 = 200,
    poll_interval_ms: u32 = 10,
    debounce_samples: u8 = 3,
};

pub fn AdcButtonSet(
    comptime Adc: type,
    comptime Runtime: type,
) type {
    comptime {
        _ = embed.runtime.is(Runtime);
        if (!embed.hal.adc.is(Adc)) @compileError("Adc must be a hal.adc type");
    }

    return struct {
        const Self = @This();

        adc: *Adc,
        time: Runtime.Time,
        config: Config,
        injector: Injector,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        current_button: ?usize = null,
        stable_count: u8 = 0,
        pending_button: ?usize = null,

        pub fn init(adc: *Adc, time: Runtime.Time, config: Config, injector: Injector) Self {
            return .{
                .adc = adc,
                .time = time,
                .config = config,
                .injector = injector,
            };
        }

        pub fn run(self: *Self) void {
            self.running.store(true, .release);
            defer self.running.store(false, .release);

            while (self.running.load(.acquire)) {
                self.tick();
                self.time.sleepMs(self.config.poll_interval_ms);
            }
        }

        pub fn runFromCtx(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return));
            self.run();
        }

        pub fn stop(self: *Self) void {
            self.running.store(false, .release);
        }

        pub fn isRunning(self: *const Self) bool {
            return self.running.load(.acquire);
        }

        fn tick(self: *Self) void {
            const mv: u32 = self.adc.readMv(self.config.adc_channel) catch return;
            const detected = self.findButton(mv);

            if (detected == self.pending_button) {
                self.stable_count +|= 1;
            } else {
                self.pending_button = detected;
                self.stable_count = 1;
            }

            if (self.stable_count < self.config.debounce_samples) return;

            if (detected == self.current_button) return;

            if (self.current_button) |old| {
                self.emitEvent(.release, old);
            }

            self.current_button = detected;

            if (detected) |new| {
                self.emitEvent(.press, new);
            }
        }

        fn findButton(self: *const Self, mv: u32) ?usize {
            if (self.isRefValue(mv)) return null;
            for (self.config.ranges, 0..) |range, i| {
                if (mv >= range.min_mv and mv <= range.max_mv) {
                    return i;
                }
            }
            return null;
        }

        fn isRefValue(self: *const Self, mv: u32) bool {
            const ref = self.config.ref_value_mv;
            const tol = self.config.ref_tolerance_mv;
            return mv >= ref -| tol and mv <= ref +| tol;
        }

        fn emitEvent(self: *Self, code: Code, range_idx: usize) void {
            self.injector.invoke(.{
                .id = self.config.ranges[range_idx].id,
                .code = code,
            });
        }
    };
}
