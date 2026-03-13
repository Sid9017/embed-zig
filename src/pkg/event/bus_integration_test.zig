//! Integration test & usage example for the event system.
//!
//! Demonstrates the complete pipeline an application would use:
//!
//!   1. Define your own EventType union(enum)
//!   2. Create a Bus(Selector, EventType)
//!   3. Register channels (button, motion sensor, ...)
//!   4. Optionally add middleware (gesture recognition, ...)
//!   5. while (running) { bus.poll() → switch on events }

const std = @import("std");
const testing = std.testing;
const event_types = @import("types.zig");
const event_bus = @import("bus.zig");
const event_motion_types = @import("motion/types.zig");
const event_button_gesture = @import("button/gesture.zig");
const event_timer_mod = @import("timer/timer.zig");

const GestureCode = event_button_gesture.GestureCode;
const MotionAction = event_motion_types.MotionAction(true);
const TimerPayload = event_timer_mod.TimerPayload;

// =========================================================================
// Step 1: Application defines its own event type
// =========================================================================

const AppEvent = union(enum) {
    button: event_types.PeriphEvent,
    motion: MotionAction,
    timer: TimerPayload,
    system: event_types.SystemEvent,
};

fn QueueChannel(comptime T: type) type {
    return struct {
        const Self = @This();

        state: *State,

        const State = struct {
            allocator: std.mem.Allocator,
            queue: std.ArrayList(T),
        };

        pub fn init(allocator: std.mem.Allocator, _: usize) !Self {
            const state = try allocator.create(State);
            errdefer allocator.destroy(state);
            state.* = .{
                .allocator = allocator,
                .queue = .empty,
            };
            return .{ .state = state };
        }

        pub fn deinit(self: *Self) void {
            self.state.queue.deinit(self.state.allocator);
            self.state.allocator.destroy(self.state);
        }

        pub const event_t = T;
        pub const RecvResult = struct { value: T, ok: bool };
        pub const SendResult = struct { ok: bool };

        pub fn close(_: *Self) void {}

        pub fn send(self: *Self, value: T) !SendResult {
            try self.state.queue.append(self.state.allocator, value);
            return .{ .ok = true };
        }

        pub fn recv(self: *Self) !RecvResult {
            if (self.state.queue.items.len == 0) return error.Empty;
            return .{ .value = self.state.queue.orderedRemove(0), .ok = true };
        }

        pub fn isSelectable() void {}
    };
}

const Channel = QueueChannel(AppEvent);

const FakeSelector = struct {
    allocator: std.mem.Allocator,
    channels: std.ArrayList(Channel),

    pub const channel_t = Channel;
    pub const event_t = AppEvent;

    pub fn init(allocator: std.mem.Allocator) !@This() {
        return .{ .allocator = allocator, .channels = .empty };
    }

    pub fn deinit(self: *@This()) void {
        self.channels.deinit(self.allocator);
    }

    pub fn add(self: *@This(), channel: Channel) !void {
        for (self.channels.items) |item| {
            if (std.meta.eql(item, channel)) return error.ChannelAlreadyRegistered;
        }
        try self.channels.append(self.allocator, channel);
    }

    pub fn remove(self: *@This(), channel: Channel) !void {
        for (self.channels.items, 0..) |item, i| {
            if (std.meta.eql(item, channel)) {
                _ = self.channels.swapRemove(i);
                return;
            }
        }
        return error.ChannelNotRegistered;
    }

    pub fn poll(self: *@This(), _: ?u32) !?AppEvent {
        for (self.channels.items) |channel| {
            var ch = channel;
            const result = ch.recv() catch |err| switch (err) {
                error.Empty => continue,
                else => return err,
            };
            if (result.ok) return result.value;
        }
        return null;
    }
};

const AppBus = event_bus.Bus(FakeSelector, AppEvent);

// =========================================================================
// Fake time — deterministic for tests
// =========================================================================

const FakeTime = struct {
    ms: u64 = 0,

    pub fn nowMs(self: *const FakeTime) u64 {
        return self.ms;
    }

    pub fn sleepMs(_: *const FakeTime, _: u32) void {}
};

// =========================================================================
// In-memory test channels
// =========================================================================

fn QueueSource(comptime EventType: type, comptime WireType: type) type {
    return struct {
        const Self = @This();

        channel: Channel,
        buildEvent: *const fn (wire: WireType) EventType,

        fn open(allocator: std.mem.Allocator, buildEvent: *const fn (wire: WireType) EventType) !Self {
            return .{
                .channel = try Channel.init(allocator, 16),
                .buildEvent = buildEvent,
            };
        }

        fn close(self: *Self) void {
            self.channel.deinit();
        }

        fn send(self: *Self, wire: WireType) void {
            const event = self.buildEvent(wire);
            _ = self.channel.send(event) catch {};
        }
    };
}

const ButtonWire = extern struct { code: u16 };

fn buildButtonEvent(wire: ButtonWire) AppEvent {
    return .{ .button = .{ .id = "btn.ok", .code = wire.code, .data = 0 } };
}

fn buildMotionEvent(action: MotionAction) AppEvent {
    return .{ .motion = action };
}

const TimerWire = extern struct { count: u32 };

fn buildTimerEvent(wire: TimerWire) AppEvent {
    return .{ .timer = .{ .id = "tick.1s", .count = wire.count, .interval_ms = 1000 } };
}

const ButtonSource = QueueSource(AppEvent, ButtonWire);
const MotionSource = QueueSource(AppEvent, MotionAction);
const TimerPipeSource = QueueSource(AppEvent, TimerWire);

// =========================================================================
// Example: full pipeline — bus + button + motion + timer + gesture
// =========================================================================

test "example: complete event pipeline with button, motion, timer, and gesture" {
    // -- init selector and bus --
    var selector = try FakeSelector.init(testing.allocator);
    defer selector.deinit();
    var bus = AppBus.init(testing.allocator, &selector);
    defer bus.deinit();

    // -- register gesture middleware (press/release → click with count) --
    var time = FakeTime{ .ms = 0 };
    const Gesture = event_button_gesture.ButtonGesture(AppEvent, "button", *FakeTime);
    var gesture = Gesture.init(&time, .{
        .multi_click_window_ms = 200,
        .long_press_ms = 500,
    });
    bus.use(gesture.middleware());

    // -- register button peripheral --
    var btn = try ButtonSource.open(testing.allocator, buildButtonEvent);
    defer btn.close();
    try bus.register(btn.channel);

    // -- register motion peripheral --
    var imu = try MotionSource.open(testing.allocator, buildMotionEvent);
    defer imu.close();
    try bus.register(imu.channel);

    // -- register timer peripheral --
    var tmr = try TimerPipeSource.open(testing.allocator, buildTimerEvent);
    defer tmr.close();
    try bus.register(tmr.channel);

    // -- simulate: button press + release (short tap) --
    btn.send(.{ .code = @intFromEnum(GestureCode.press) });
    time.ms = 40;
    btn.send(.{ .code = @intFromEnum(GestureCode.release) });

    // -- simulate: IMU detects a shake --
    imu.send(.{ .shake = .{ .magnitude = 2.5, .duration_ms = 200 } });

    // -- simulate: timer tick --
    tmr.send(.{ .count = 1 });

    // -- poll loop (simulates the app's main loop) --
    var out: [16]AppEvent = undefined;
    var saw_click = false;
    var saw_shake = false;
    var saw_timer = false;

    // poll 1: raw button events enter gesture middleware (buffered),
    //         motion shake and timer tick pass through immediately
    {
        const got = try bus.poll(&out, 200);
        for (got) |ev| {
            switch (ev) {
                .button => |b| {
                    if (b.code == @intFromEnum(GestureCode.click)) saw_click = true;
                },
                .motion => |m| switch (m) {
                    .shake => |s| {
                        try testing.expectApproxEqAbs(@as(f32, 2.5), s.magnitude, 0.01);
                        saw_shake = true;
                    },
                    else => {},
                },
                .timer => |t| {
                    try testing.expectEqualStrings("tick.1s", t.id);
                    try testing.expectEqual(@as(u32, 1), t.count);
                    saw_timer = true;
                },
                .system => {},
            }
        }
    }

    // poll 2: advance time past click_timeout → gesture tick emits click
    time.ms = 400;
    {
        const got = try bus.poll(&out, 0);
        for (got) |ev| {
            switch (ev) {
                .button => |b| {
                    if (b.code == @intFromEnum(GestureCode.click)) {
                        try testing.expectEqualStrings("btn.ok", b.id);
                        saw_click = true;
                    }
                },
                .motion => |m| switch (m) {
                    .shake => {
                        saw_shake = true;
                    },
                    else => {},
                },
                .timer => |t| {
                    _ = t;
                    saw_timer = true;
                },
                .system => {},
            }
        }
    }

    try testing.expect(saw_click);
    try testing.expect(saw_shake);
    try testing.expect(saw_timer);
}

// =========================================================================
// Example: system events pass through the full pipeline untouched
// =========================================================================

test "example: system events pass through middleware" {
    var selector = try FakeSelector.init(testing.allocator);
    defer selector.deinit();
    var bus = AppBus.init(testing.allocator, &selector);
    defer bus.deinit();

    var time = FakeTime{ .ms = 0 };
    const Gesture = event_button_gesture.ButtonGesture(AppEvent, "button", *FakeTime);
    var gesture = Gesture.init(&time, .{});
    bus.use(gesture.middleware());

    // inject a system event directly
    bus.ready.append(testing.allocator, .{ .system = .low_battery }) catch {};

    var out: [4]AppEvent = undefined;
    const got = try bus.poll(&out, 0);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(AppEvent{ .system = .low_battery }, got[0]);
}

// =========================================================================
// Example: multiple button peripherals + motion on same bus
// =========================================================================

test "example: multiple peripherals on same bus" {
    var selector = try FakeSelector.init(testing.allocator);
    defer selector.deinit();
    var bus = AppBus.init(testing.allocator, &selector);
    defer bus.deinit();

    const buildBtnA = struct {
        fn f(wire: ButtonWire) AppEvent {
            return .{ .button = .{ .id = "btn.a", .code = wire.code, .data = 0 } };
        }
    }.f;
    const buildBtnB = struct {
        fn f(wire: ButtonWire) AppEvent {
            return .{ .button = .{ .id = "btn.b", .code = wire.code, .data = 0 } };
        }
    }.f;

    var btn_a = try ButtonSource.open(testing.allocator, buildBtnA);
    defer btn_a.close();
    var btn_b = try ButtonSource.open(testing.allocator, buildBtnB);
    defer btn_b.close();
    var imu = try MotionSource.open(testing.allocator, buildMotionEvent);
    defer imu.close();

    try bus.register(btn_a.channel);
    try bus.register(btn_b.channel);
    try bus.register(imu.channel);

    btn_a.send(.{ .code = 1 });
    btn_b.send(.{ .code = 2 });
    imu.send(.{ .tap = .{ .axis = .x, .count = 1, .positive = true } });

    var out: [16]AppEvent = undefined;
    const got = try bus.poll(&out, 200);
    try testing.expectEqual(@as(usize, 3), got.len);
}
