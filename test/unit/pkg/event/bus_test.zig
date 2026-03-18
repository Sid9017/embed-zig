const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const bus_mod = embed.pkg.event.bus;
const Bus = bus_mod.Bus;
const Std = embed.runtime.std;

const TestPayload = struct { value: u32 };

const TestBus = Bus(.{
    .src_a = TestPayload,
    .src_b = TestPayload,
}, .{
    .transformed = TestPayload,
}, Std);

test "init and deinit" {
    var bus = try TestBus.init(testing.allocator, 16);
    defer bus.deinit();
}

test "inject and recv pass through without middleware" {
    var bus = try TestBus.init(testing.allocator, 16);
    defer bus.deinit();

    const t = try std.Thread.spawn(.{}, TestBus.run, .{&bus});

    _ = try bus.inject(.src_a, .{ .value = 42 });

    const r = try bus.recv();
    try testing.expect(r.ok);
    try testing.expectEqual(TestBus.BusEvent{ .input = .{ .src_a = .{ .value = 42 } } }, r.value);

    bus.stop();
    t.join();
}

test "multiple inject and recv" {
    var bus = try TestBus.init(testing.allocator, 16);
    defer bus.deinit();

    const t = try std.Thread.spawn(.{}, TestBus.run, .{&bus});

    _ = try bus.inject(.src_a, .{ .value = 1 });
    _ = try bus.inject(.src_b, .{ .value = 2 });

    const r1 = try bus.recv();
    try testing.expect(r1.ok);
    try testing.expectEqual(TestBus.BusEvent{ .input = .{ .src_a = .{ .value = 1 } } }, r1.value);

    const r2 = try bus.recv();
    try testing.expect(r2.ok);
    try testing.expectEqual(TestBus.BusEvent{ .input = .{ .src_b = .{ .value = 2 } } }, r2.value);

    bus.stop();
    t.join();
}

test "Injector produces typed callback for peripherals" {
    var bus = try TestBus.init(testing.allocator, 16);
    defer bus.deinit();

    const t = try std.Thread.spawn(.{}, TestBus.run, .{&bus});

    const injector = bus.Injector(.src_a);
    injector.invoke(.{ .value = 99 });

    const r = try bus.recv();
    try testing.expect(r.ok);
    try testing.expectEqual(TestBus.BusEvent{ .input = .{ .src_a = .{ .value = 99 } } }, r.value);

    bus.stop();
    t.join();
}

const DoubleImpl = struct {
    pub fn init() @This() {
        return .{};
    }

    pub fn deinit(_: *@This()) void {}

    pub fn process(_: *@This(), payload: TestPayload, yield_ctx: ?*anyopaque, yield: *const fn (?*anyopaque, TestPayload) void) void {
        yield(yield_ctx, .{ .value = payload.value * 2 });
    }

    pub fn tick(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, TestPayload) void) void {}
};

test "Processor middleware transforms events" {
    var bus = try TestBus.init(testing.allocator, 16);
    defer bus.deinit();

    const mw = try TestBus.Processor(.src_a, .transformed, DoubleImpl).init(testing.allocator);
    defer mw.deinit();
    bus.use(mw);

    const t = try std.Thread.spawn(.{}, TestBus.run, .{&bus});

    _ = try bus.inject(.src_a, .{ .value = 5 });

    const r = try bus.recv();
    try testing.expect(r.ok);
    try testing.expectEqual(TestBus.BusEvent{ .transformed = .{ .value = 10 } }, r.value);

    bus.stop();
    t.join();
}

test "Processor bypasses non-matching input tags" {
    var bus = try TestBus.init(testing.allocator, 16);
    defer bus.deinit();

    const mw = try TestBus.Processor(.src_a, .transformed, DoubleImpl).init(testing.allocator);
    defer mw.deinit();
    bus.use(mw);

    const t = try std.Thread.spawn(.{}, TestBus.run, .{&bus});

    _ = try bus.inject(.src_b, .{ .value = 7 });

    const r = try bus.recv();
    try testing.expect(r.ok);
    try testing.expectEqual(TestBus.BusEvent{ .input = .{ .src_b = .{ .value = 7 } } }, r.value);

    bus.stop();
    t.join();
}

const DropAllImpl = struct {
    pub fn init() @This() {
        return .{};
    }

    pub fn deinit(_: *@This()) void {}

    pub fn process(_: *@This(), _: TestBus.BusEvent, _: ?*anyopaque, _: *const fn (?*anyopaque, TestBus.BusEvent) void) void {}

    pub fn tick(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, TestBus.BusEvent) void) void {}
};

test "Middleware can swallow events" {
    var bus = try TestBus.init(testing.allocator, 16);
    defer bus.deinit();

    const mw = try TestBus.Middleware(DropAllImpl).init(testing.allocator);
    defer mw.deinit();
    bus.use(mw);

    const t = try std.Thread.spawn(.{}, TestBus.run, .{&bus});

    _ = try bus.inject(.src_a, .{ .value = 1 });
    _ = try bus.inject(.src_b, .{ .value = 2 });

    std.Thread.sleep(50 * std.time.ns_per_ms);

    bus.stop();
    t.join();

    const r = bus.recv() catch |e| switch (e) {
        else => return,
    };
    try testing.expect(!r.ok);
}

const PassThroughImpl = struct {
    pub fn init() @This() {
        return .{};
    }

    pub fn deinit(_: *@This()) void {}

    pub fn process(_: *@This(), ev: TestBus.BusEvent, yield_ctx: ?*anyopaque, yield: *const fn (?*anyopaque, TestBus.BusEvent) void) void {
        yield(yield_ctx, ev);
    }

    pub fn tick(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, TestBus.BusEvent) void) void {}
};

test "Middleware passes events through unchanged" {
    var bus = try TestBus.init(testing.allocator, 16);
    defer bus.deinit();

    const mw = try TestBus.Middleware(PassThroughImpl).init(testing.allocator);
    defer mw.deinit();
    bus.use(mw);

    const t = try std.Thread.spawn(.{}, TestBus.run, .{&bus});

    _ = try bus.inject(.src_a, .{ .value = 42 });

    const r = try bus.recv();
    try testing.expect(r.ok);
    try testing.expectEqual(TestBus.BusEvent{ .input = .{ .src_a = .{ .value = 42 } } }, r.value);

    bus.stop();
    t.join();
}

test "stop signals run loop to exit" {
    var bus = try TestBus.init(testing.allocator, 16);
    defer bus.deinit();

    const t = try std.Thread.spawn(.{}, TestBus.run, .{&bus});

    std.Thread.sleep(10 * std.time.ns_per_ms);
    bus.stop();
    t.join();
}
