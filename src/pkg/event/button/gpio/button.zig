//! GPIO button — polls a pin, writes press/release events to a channel
//! that the event bus can multiplex.
//!
//! The caller is responsible for running the polling loop. Call `run()`
//! from a dedicated thread/task; call `requestStop()` to exit the loop.

const std = @import("std");
const hal = struct {
    pub const gpio = @import("../../../../hal/gpio.zig");
};
const event_pkg = struct {
    pub const types = @import("../../types.zig");
};
const runtime_pkg = struct {
    pub const channel = @import("../../../../runtime/channel.zig");
};

pub const BusButtonCode = enum(u16) {
    press = 1,
    release = 2,
};

pub const Level = hal.gpio.Level;

pub const Config = struct {
    id: []const u8 = "button",
    pin: u8,
    active_level: Level = .high,
    debounce_ms: u32 = 20,
    poll_interval_ms: u32 = 10,
};

pub fn Button(
    comptime Gpio: type,
    comptime Time: type,
    comptime ChannelType: type,
    comptime EventType: type,
    comptime tag: []const u8,
) type {
    comptime {
        if (!hal.gpio.is(Gpio)) @compileError("Gpio must be a hal.gpio type");
        _ = runtime_pkg.channel.from(EventType, ChannelType);
        event_pkg.types.assertTaggedUnion(EventType);
    }

    return struct {
        const Self = @This();

        channel: ChannelType,
        gpio: *Gpio,
        time: Time,
        config: Config,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        state: State = .idle,
        last_raw: bool = false,
        debounce_start_ms: u64 = 0,
        pressed: bool = false,

        const State = enum { idle, debouncing };

        pub fn init(allocator: std.mem.Allocator, gpio: *Gpio, time: Time, config: Config) !Self {
            const ch = try ChannelType.init(allocator, 16);

            return .{
                .channel = ch,
                .gpio = gpio,
                .time = time,
                .config = config,
            };
        }

        pub fn deinit(self: *Self) void {
            self.requestStop();
            self.channel.deinit();
        }

        /// Blocking polling loop. Call from a dedicated thread/task.
        /// Returns when `requestStop()` is called.
        pub fn run(self: *Self) void {
            self.running.store(true, .release);
            defer self.running.store(false, .release);

            while (self.running.load(.acquire)) {
                self.tick();
                self.time.sleepMs(self.config.poll_interval_ms);
            }
        }

        /// Convenience: `run` as a `fn(?*anyopaque) void` for Thread.spawn.
        pub fn runFromCtx(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return));
            self.run();
        }

        pub fn requestStop(self: *Self) void {
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
                            self.sendEvent(if (raw) .press else .release);
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

        fn sendEvent(self: *Self, code: BusButtonCode) void {
            const event = @unionInit(EventType, tag, .{
                .id = self.config.id,
                .code = @intFromEnum(code),
                .data = 0,
            });
            _ = self.channel.send(event) catch {};
        }
    };
}
