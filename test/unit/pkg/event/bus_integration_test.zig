//! Integration test for the new event bus pipeline.
//!
//! Demonstrates:
//!   1. Define input/output specs
//!   2. Create Bus(input, output, ChannelImpl)
//!   3. Use Injector to push events
//!   4. Register Processor middleware (ButtonGesture)
//!   5. Register generic Middleware
//!   6. bus.run() drives the chain, bus.recv() reads processed events

const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const bus_mod = embed.pkg.event.bus;
const Bus = bus_mod.Bus;
const event = embed.pkg.event;
const Std = embed.runtime.std;

const RawEvent = event.button.RawEvent;
const GestureEvent = event.button.GestureEvent;
const GestureConfig = event.button.GestureConfig;

var fake_time_ms: u64 = 0;

const FakeTime = struct {
    pub fn nowMs(_: FakeTime) u64 {
        return fake_time_ms;
    }
    pub fn sleepMs(_: FakeTime, _: u32) void {}
    pub fn setMs(val: u64) void {
        fake_time_ms = val;
    }
};

const runtime_suite = embed.runtime.suite;
const FakeRuntime = runtime_suite.Make(struct {
    pub const Time = FakeTime;
    pub const Log = @import("../../../../src/runtime/std/log.zig").Log;
    pub const Rng = @import("../../../../src/runtime/std/rng.zig").Rng;
    pub const Mutex = @import("../../../../src/runtime/std/sync/mutex.zig").Mutex;
    pub const Condition = @import("../../../../src/runtime/std/sync/condition.zig").Condition;
    pub const Notify = @import("../../../../src/runtime/std/sync/notify.zig").Notify;
    pub const Thread = @import("../../../../src/runtime/std/thread.zig").Thread;
    pub const System = @import("../../../../src/runtime/std/system.zig").System;
    pub const Fs = @import("../../../../src/runtime/std/fs.zig").Fs;
    pub const ChannelFactory = @import("../../../../src/runtime/std/channel_factory.zig").ChannelFactory;
    pub const Socket = @import("../../../../src/runtime/std/socket.zig").Socket;
    pub const OtaBackend = @import("../../../../src/runtime/std/ota_backend.zig").OtaBackend;
    pub const Crypto = @import("../../../../src/runtime/std/crypto/suite.zig");
});

const AppBus = Bus(.{
    .btn_ok = RawEvent,
    .btn_vol = RawEvent,
}, .{
    .gesture = GestureEvent,
}, Std);

const Gesture = event.button.ButtonGesture(FakeRuntime, .{
    .multi_click_window_ms = 200,
    .long_press_ms = 500,
});

test "complete pipeline: event.button press/release → gesture click via Processor" {
    var bus = try AppBus.init(testing.allocator, 16);
    defer bus.deinit();

    const gp = try AppBus.Processor(.btn_ok, .gesture, Gesture).init(testing.allocator);
    defer gp.deinit();
    bus.use(gp);

    const t = try std.Thread.spawn(.{}, AppBus.run, .{&bus});

    _ = try bus.inject(.btn_ok, .{ .code = .press });

    const gp_impl: *Gesture = &gp.impl;
    FakeTime.setMs(40);

    _ = try bus.inject(.btn_ok, .{ .code = .release });

    FakeTime.setMs(400);

    _ = try bus.inject(.tick, gp_impl.time.nowMs());

    const r = try bus.recv();
    try testing.expect(r.ok);
    try testing.expectEqual(AppBus.BusEvent{ .gesture = .{
        .id = "",
        .gesture = .{ .click = 1 },
    } }, r.value);

    bus.stop();
    t.join();
}

test "non-matching input passes through Processor unchanged" {
    var bus = try AppBus.init(testing.allocator, 16);
    defer bus.deinit();

    const gp = try AppBus.Processor(.btn_ok, .gesture, Gesture).init(testing.allocator);
    defer gp.deinit();
    bus.use(gp);

    const t = try std.Thread.spawn(.{}, AppBus.run, .{&bus});

    _ = try bus.inject(.btn_vol, .{ .code = .press });

    const r = try bus.recv();
    try testing.expect(r.ok);
    try testing.expectEqual(
        AppBus.BusEvent{ .input = .{ .btn_vol = .{ .id = "", .code = .press } } },
        r.value,
    );

    bus.stop();
    t.join();
}

const CountingImpl = struct {
    count: u32,

    pub fn init() @This() {
        return .{ .count = 0 };
    }

    pub fn deinit(_: *@This()) void {}

    pub fn process(self: *@This(), ev: AppBus.BusEvent, yield_ctx: ?*anyopaque, yield: *const fn (?*anyopaque, AppBus.BusEvent) void) void {
        self.count += 1;
        yield(yield_ctx, ev);
    }

    pub fn tick(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, AppBus.BusEvent) void) void {}
};

test "generic Middleware sees all events" {
    var bus = try AppBus.init(testing.allocator, 16);
    defer bus.deinit();

    const mw = try AppBus.Middleware(CountingImpl).init(testing.allocator);
    defer mw.deinit();
    bus.use(mw);

    const t = try std.Thread.spawn(.{}, AppBus.run, .{&bus});

    _ = try bus.inject(.btn_ok, .{ .code = .press });
    _ = try bus.inject(.btn_vol, .{ .code = .release });

    _ = try bus.recv();
    _ = try bus.recv();

    try testing.expectEqual(@as(u32, 2), mw.impl.count);

    bus.stop();
    t.join();
}

test "chained Processor + Middleware" {
    var bus = try AppBus.init(testing.allocator, 16);
    defer bus.deinit();

    const gp = try AppBus.Processor(.btn_ok, .gesture, Gesture).init(testing.allocator);
    defer gp.deinit();
    bus.use(gp);

    const counter = try AppBus.Middleware(CountingImpl).init(testing.allocator);
    defer counter.deinit();
    bus.use(counter);

    const t = try std.Thread.spawn(.{}, AppBus.run, .{&bus});

    _ = try bus.inject(.btn_ok, .{ .code = .press });

    const gp_impl: *Gesture = &gp.impl;
    FakeTime.setMs(40);
    _ = try bus.inject(.btn_ok, .{ .code = .release });

    FakeTime.setMs(400);
    _ = try bus.inject(.tick, gp_impl.time.nowMs());

    const r = try bus.recv();
    try testing.expect(r.ok);
    try testing.expectEqual(AppBus.BusEvent{ .gesture = .{
        .id = "",
        .gesture = .{ .click = 1 },
    } }, r.value);

    try testing.expect(counter.impl.count >= 1);

    bus.stop();
    t.join();
}

test "Injector callback works for peripherals" {
    var bus = try AppBus.init(testing.allocator, 16);
    defer bus.deinit();

    const t = try std.Thread.spawn(.{}, AppBus.run, .{&bus});

    const injector = bus.Injector(.btn_ok);
    injector.invoke(.{ .code = .press });

    const r = try bus.recv();
    try testing.expect(r.ok);
    try testing.expectEqual(
        AppBus.BusEvent{ .input = .{ .btn_ok = .{ .id = "", .code = .press } } },
        r.value,
    );

    bus.stop();
    t.join();
}
