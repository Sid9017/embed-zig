const std = @import("std");
const embed = @import("embed");
const runtime = embed.runtime;
const websim = embed.websim;
const led_strip = embed.hal.led_strip;
const gpio = embed.hal.gpio;
const RemoteHal = websim.RemoteHal;
const Gpio = websim.hal.Gpio;

pub threadlocal var session_bus: ?*RemoteHal = null;
pub threadlocal var session_running: ?*std.atomic.Value(bool) = null;
pub threadlocal var session_gpio: ?*Gpio = null;

pub const SessionCtx = struct {
    gpio: Gpio,
};

pub const SessionSetup = struct {
    pub fn setup(bus: *RemoteHal, running: *std.atomic.Value(bool)) SessionCtx {
        session_bus = bus;
        session_running = running;
        return .{ .gpio = .{ .vcc = 3.3 } };
    }

    pub fn bind(ctx: *SessionCtx, bus: *RemoteHal) void {
        session_gpio = &ctx.gpio;
        ctx.gpio.registerOn(bus);
    }

    pub fn teardown(_: *SessionCtx) void {
        session_bus = null;
        session_running = null;
        session_gpio = null;
    }
};

pub const hw = struct {
    pub const name: []const u8 = "websim";
    pub const button_pin: u8 = 0;

    pub const allocator = struct {
        pub const user = std.heap.page_allocator;
        pub const system = std.heap.page_allocator;
        pub const default = std.heap.page_allocator;
    };

    pub const thread = struct {
        pub const Thread = runtime.std.Thread;
        pub const user_defaults: runtime.thread.SpawnConfig = .{
            .priority = 3,
            .name = "user",
        };
        pub const system_defaults: runtime.thread.SpawnConfig = .{
            .priority = 5,
            .name = "sys",
        };
        pub const default_defaults: runtime.thread.SpawnConfig = .{
            .priority = 5,
            .name = "zig-task",
        };
    };

    pub const log = runtime.std.Log;
    pub const time = runtime.std.Time;
    pub const io = runtime.std.IO;

    pub const isRunning = struct {
        fn check() bool {
            const r = session_running orelse return false;
            return r.load(.acquire);
        }
    }.check;

    pub const rtc_spec = struct {
        pub const Driver = websim.hal.Rtc;
        pub const meta = .{ .id = "rtc.websim" };
    };

    pub const gpio_spec = struct {
        pub const Driver = struct {
            inner: ?*Gpio,

            const Self = @This();

            pub fn init() Self {
                return .{ .inner = session_gpio };
            }

            pub fn deinit(_: *Self) void {}

            pub fn setMode(self: *Self, pin: u8, mode: embed.hal.gpio.Mode) embed.hal.gpio.Error!void {
                const g = self.inner orelse return error.GpioError;
                return g.setMode(pin, mode);
            }

            pub fn setLevel(self: *Self, pin: u8, level: gpio.Level) embed.hal.gpio.Error!void {
                const g = self.inner orelse return error.GpioError;
                return g.setLevel(pin, level);
            }

            pub fn getLevel(self: *Self, pin: u8) embed.hal.gpio.Error!gpio.Level {
                const g = self.inner orelse return error.GpioError;
                return g.getLevel(pin);
            }

            pub fn setPull(self: *Self, pin: u8, pull: embed.hal.gpio.Pull) embed.hal.gpio.Error!void {
                const g = self.inner orelse return error.GpioError;
                return g.setPull(pin, pull);
            }
        };
        pub const meta = .{ .id = "gpio.websim" };
    };

    pub const led_strip_spec = struct {
        pub const Driver = struct {
            inner: websim.hal.LedStrip,

            const Self = @This();

            pub fn init() Self {
                return .{ .inner = .{ .bus = session_bus } };
            }

            pub fn deinit(_: *Self) void {}

            pub fn setPixel(self: *Self, index: u32, color: led_strip.Color) void {
                self.inner.setPixel(index, color);
            }

            pub fn getPixelCount(self: *Self) u32 {
                return self.inner.getPixelCount();
            }

            pub fn refresh(self: *Self) void {
                self.inner.refresh();
            }
        };
        pub const meta = .{ .id = "led_strip.websim" };
    };
};
