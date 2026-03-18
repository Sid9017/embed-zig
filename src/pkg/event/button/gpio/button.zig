//! GPIO button — polls a pin, fires callback on press/release.
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

const Level = embed.hal.gpio.Level;

pub const Config = struct {
    pin: u8,
    active_level: Level = .high,
    debounce_ms: u32 = 20,
    poll_interval_ms: u32 = 10,
};

pub fn Button(
    comptime Gpio: type,
    comptime Runtime: type,
    comptime id: []const u8,
) type {
    comptime {
        _ = embed.runtime.is(Runtime);
        if (!embed.hal.gpio.is(Gpio)) @compileError("Gpio must be a hal.gpio type");
    }

    return struct {
        const Self = @This();

        gpio: *Gpio,
        time: Runtime.Time,
        config: Config,
        injector: Injector,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        state: State = .idle,
        last_raw: bool = false,
        debounce_start_ms: u64 = 0,
        pressed: bool = false,

        const State = enum { idle, debouncing };

        pub fn init(gpio: *Gpio, time: Runtime.Time, config: Config, injector: Injector) Self {
            return .{
                .gpio = gpio,
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
            const now_ms = self.time.nowMs();
            const raw = self.readRawPressed();

            switch (self.state) {
                .idle => {
                    if (raw != self.last_raw) {
                        self.state = .debouncing;
                        self.debounce_start_ms = now_ms;
                    }
                },
                .debouncing => {
                    if (now_ms >= self.debounce_start_ms + self.config.debounce_ms) {
                        if (raw != self.pressed) {
                            self.pressed = raw;
                            const code: Code = if (raw) .press else .release;
                            self.injector.invoke(.{ .id = id, .code = code });
                        }
                        self.state = .idle;
                    }
                },
            }

            self.last_raw = raw;
        }

        fn readRawPressed(self: *Self) bool {
            const lv = self.gpio.getLevel(self.config.pin) catch return self.pressed;
            return lv == self.config.active_level;
        }
    };
}
