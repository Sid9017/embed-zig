//! Selector-driven event bus, generic over EventType.
//!
//! `Bus` is a thin wrapper around a selector that adds:
//! - registration of multiple channels
//! - buffering of ready events
//! - a middleware pipeline
//! - batched `poll()` output

const std = @import("std");
const types = @import("types.zig");
const mw_mod = @import("middleware.zig");

pub fn Bus(comptime Selector: type, comptime EventType: type) type {
    comptime {
        _ = @as(type, Selector.channel_t);
        _ = @as(type, Selector.event_t);
        _ = @as(*const fn (std.mem.Allocator) anyerror!Selector, &Selector.init);
        _ = @as(*const fn (*Selector) void, &Selector.deinit);
        _ = @as(*const fn (*Selector, Selector.channel_t) anyerror!void, &Selector.add);
        _ = @as(*const fn (*Selector, Selector.channel_t) anyerror!void, &Selector.remove);
        _ = @as(*const fn (*Selector, ?u32) anyerror!?Selector.event_t, &Selector.poll);
        _ = @as(*const fn () void, &Selector.channel_t.isSelectable);
        types.assertTaggedUnion(EventType);
        if (Selector.event_t != EventType) {
            @compileError("Bus requires `Selector.event_t == EventType`");
        }
    }

    const ChannelType = Selector.channel_t;
    const MiddlewareType = mw_mod.Middleware(EventType);

    return struct {
        const Self = @This();

        pub const Event = EventType;
        pub const Channel = ChannelType;
        pub const Mw = MiddlewareType;

        allocator: std.mem.Allocator,
        selector: *Selector,
        channels: std.ArrayList(ChannelType),
        ready: std.ArrayList(EventType),
        middlewares: std.ArrayList(MiddlewareType),
        processed: std.ArrayList(EventType),

        pub fn init(allocator: std.mem.Allocator, selector: *Selector) Self {
            return .{
                .allocator = allocator,
                .selector = selector,
                .channels = .empty,
                .ready = .empty,
                .middlewares = .empty,
                .processed = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.channels.items) |channel| {
                self.selector.remove(channel) catch {};
            }
            self.channels.deinit(self.allocator);
            self.ready.deinit(self.allocator);
            self.middlewares.deinit(self.allocator);
            self.processed.deinit(self.allocator);
        }

        pub fn use(self: *Self, middleware: MiddlewareType) void {
            self.middlewares.append(self.allocator, middleware) catch {};
        }

        pub fn register(self: *Self, channel: ChannelType) !void {
            for (self.channels.items) |item| {
                if (std.meta.eql(item, channel)) {
                    return error.ChannelAlreadyRegistered;
                }
            }

            try self.selector.add(channel);
            errdefer self.selector.remove(channel) catch {};
            try self.channels.append(self.allocator, channel);
        }

        pub fn unregister(self: *Self, channel: ChannelType) !void {
            for (self.channels.items, 0..) |item, i| {
                if (std.meta.eql(item, channel)) {
                    try self.selector.remove(channel);
                    _ = self.channels.swapRemove(i);
                    return;
                }
            }
            return error.ChannelNotRegistered;
        }

        pub fn poll(self: *Self, out: []EventType, timeout_ms: ?u32) ![]EventType {
            if (self.ready.items.len == 0 and self.processed.items.len == 0) {
                try self.collectReady(timeout_ms);
            }
            self.applyMiddlewares();
            return self.drain(out);
        }

        fn applyMiddlewares(self: *Self) void {
            if (self.middlewares.items.len == 0) {
                for (self.ready.items) |ev| {
                    self.processed.append(self.allocator, ev) catch {};
                }
                self.ready.items.len = 0;
                return;
            }

            for (self.ready.items) |ev| {
                self.runChain(ev, 0);
            }
            self.ready.items.len = 0;

            for (self.middlewares.items, 0..) |middleware, i| {
                if (middleware.tickFn) |tick| {
                    var ctx = ChainCtx{ .bus = self, .next_idx = i + 1 };
                    tick(middleware.ctx, 0, @ptrCast(&ctx), chainEmit);
                }
            }
        }

        fn runChain(self: *Self, ev: EventType, idx: usize) void {
            if (idx >= self.middlewares.items.len) {
                self.processed.append(self.allocator, ev) catch {};
                return;
            }

            const mw = self.middlewares.items[idx];
            var ctx = ChainCtx{ .bus = self, .next_idx = idx + 1 };
            if (mw.processFn) |processFn| {
                processFn(mw.ctx, ev, @ptrCast(&ctx), chainEmit);
            } else {
                chainEmit(@ptrCast(&ctx), ev);
            }
        }

        const ChainCtx = struct {
            bus: *Self,
            next_idx: usize,
        };

        fn chainEmit(raw: *anyopaque, ev: EventType) void {
            const ctx: *ChainCtx = @ptrCast(@alignCast(raw));
            ctx.bus.runChain(ev, ctx.next_idx);
        }

        fn collectReady(self: *Self, timeout_ms: ?u32) !void {
            var next_timeout = timeout_ms;
            while (true) {
                const ready_event = try self.selector.poll(next_timeout) orelse break;
                try self.ready.append(self.allocator, ready_event);
                next_timeout = 0;
            }
        }

        fn drain(self: *Self, out: []EventType) []EventType {
            const src = &self.processed;
            const n = @min(src.items.len, out.len);
            if (n == 0) return out[0..0];
            @memcpy(out[0..n], src.items[0..n]);
            const remain = src.items.len - n;
            if (remain > 0) {
                std.mem.copyForwards(EventType, src.items[0..remain], src.items[n..]);
            }
            src.items.len = remain;
            return out[0..n];
        }
    };
}

// ---------------------------------------------------------------------------
// Tests — fake selector returns EventType directly
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestChannel = struct {
    id: u8,

    pub fn isSelectable() void {}
};

const TestEvent = union(enum) {
    button: types.PeriphEvent,
    system: types.SystemEvent,
};

const FakeSelector = struct {
    allocator: std.mem.Allocator,
    watched: std.ArrayList(TestChannel),
    pending: std.ArrayList(PendingEvent),

    const PendingEvent = struct {
        channel: TestChannel,
        event: TestEvent,
    };

    pub const channel_t = TestChannel;
    pub const event_t = TestEvent;

    pub fn init(allocator: std.mem.Allocator) !@This() {
        return .{
            .allocator = allocator,
            .watched = .empty,
            .pending = .empty,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.watched.deinit(self.allocator);
        self.pending.deinit(self.allocator);
    }

    pub fn add(self: *@This(), channel: TestChannel) !void {
        for (self.watched.items) |item| {
            if (std.meta.eql(item, channel)) {
                return error.ChannelAlreadyRegistered;
            }
        }
        try self.watched.append(self.allocator, channel);
    }

    pub fn remove(self: *@This(), channel: TestChannel) !void {
        for (self.watched.items, 0..) |item, i| {
            if (std.meta.eql(item, channel)) {
                _ = self.watched.swapRemove(i);
                return;
            }
        }
        return error.ChannelNotRegistered;
    }

    pub fn poll(self: *@This(), _: ?u32) !?TestEvent {
        if (self.pending.items.len == 0) return null;
        return self.pending.orderedRemove(0).event;
    }

    fn signal(self: *@This(), channel: TestChannel, event: TestEvent) !void {
        for (self.watched.items) |item| {
            if (std.meta.eql(item, channel)) {
                try self.pending.append(self.allocator, .{
                    .channel = channel,
                    .event = event,
                });
                return;
            }
        }
        return error.ChannelNotRegistered;
    }
};

const TestBus = Bus(FakeSelector, TestEvent);

test "register channel and collect events via poll" {
    var selector = try FakeSelector.init(testing.allocator);
    defer selector.deinit();
    var bus = TestBus.init(testing.allocator, &selector);
    defer bus.deinit();

    const channel = TestChannel{ .id = 1 };
    try bus.register(channel);

    try selector.signal(channel, .{ .button = .{ .id = "btn.a", .code = 10, .data = 0 } });
    try selector.signal(channel, .{ .button = .{ .id = "btn.a", .code = 11, .data = 0 } });

    var out: [8]TestEvent = undefined;
    const got = try bus.poll(&out, 200);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("btn.a", got[0].button.id);
    try testing.expectEqual(@as(u16, 10), got[0].button.code);
    try testing.expectEqual(@as(u16, 11), got[1].button.code);
}

test "multiple channels on same bus" {
    var selector = try FakeSelector.init(testing.allocator);
    defer selector.deinit();
    var bus = TestBus.init(testing.allocator, &selector);
    defer bus.deinit();

    const button_channel = TestChannel{ .id = 1 };
    const sensor_channel = TestChannel{ .id = 2 };
    try bus.register(button_channel);
    try bus.register(sensor_channel);

    try selector.signal(button_channel, .{ .button = .{ .id = "btn.a", .code = 1, .data = 0 } });
    try selector.signal(sensor_channel, .{ .button = .{ .id = "sensor.0", .code = 2, .data = 0 } });

    var out: [8]TestEvent = undefined;
    const got = try bus.poll(&out, 200);
    try testing.expectEqual(@as(usize, 2), got.len);
}

test "unregister removes channel from poll" {
    var selector = try FakeSelector.init(testing.allocator);
    defer selector.deinit();
    var bus = TestBus.init(testing.allocator, &selector);
    defer bus.deinit();

    const channel = TestChannel{ .id = 1 };
    try bus.register(channel);
    try bus.unregister(channel);
    try testing.expectError(error.ChannelNotRegistered, selector.signal(channel, .{
        .button = .{ .id = "btn.x", .code = 99, .data = 0 },
    }));

    var out: [4]TestEvent = undefined;
    const got = try bus.poll(&out, 50);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "poll with no ready events returns empty" {
    var selector = try FakeSelector.init(testing.allocator);
    defer selector.deinit();
    var bus = TestBus.init(testing.allocator, &selector);
    defer bus.deinit();

    var out: [4]TestEvent = undefined;
    const got = try bus.poll(&out, 0);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "middleware transforms events" {
    var selector = try FakeSelector.init(testing.allocator);
    defer selector.deinit();
    var bus = TestBus.init(testing.allocator, &selector);
    defer bus.deinit();

    const DoubleCode = struct {
        fn process(_: ?*anyopaque, ev: TestEvent, emit_ctx: *anyopaque, emit: mw_mod.EmitFn(TestEvent)) void {
            switch (ev) {
                .button => |b| emit(emit_ctx, .{
                    .button = .{ .id = b.id, .code = b.code * 2, .data = b.data },
                }),
                else => emit(emit_ctx, ev),
            }
        }
    };

    bus.use(.{ .ctx = null, .processFn = DoubleCode.process, .tickFn = null });

    const channel = TestChannel{ .id = 1 };
    try bus.register(channel);
    try selector.signal(channel, .{ .button = .{ .id = "btn.m", .code = 5, .data = 0 } });

    var out: [4]TestEvent = undefined;
    const got = try bus.poll(&out, 200);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(u16, 10), got[0].button.code);
}

test "middleware can swallow events" {
    var selector = try FakeSelector.init(testing.allocator);
    defer selector.deinit();
    var bus = TestBus.init(testing.allocator, &selector);
    defer bus.deinit();

    const DropAll = struct {
        fn process(_: ?*anyopaque, _: TestEvent, _: *anyopaque, _: mw_mod.EmitFn(TestEvent)) void {}
    };

    bus.use(.{ .ctx = null, .processFn = DropAll.process, .tickFn = null });

    const channel = TestChannel{ .id = 1 };
    try bus.register(channel);
    try selector.signal(channel, .{ .button = .{ .id = "btn.d", .code = 1, .data = 0 } });

    var out: [4]TestEvent = undefined;
    const got = try bus.poll(&out, 100);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "non-button events pass through middleware" {
    var selector = try FakeSelector.init(testing.allocator);
    defer selector.deinit();
    var bus = TestBus.init(testing.allocator, &selector);
    defer bus.deinit();

    const ButtonOnly = struct {
        fn process(_: ?*anyopaque, ev: TestEvent, emit_ctx: *anyopaque, emit: mw_mod.EmitFn(TestEvent)) void {
            switch (ev) {
                .button => {},
                else => emit(emit_ctx, ev),
            }
        }
    };

    bus.use(.{ .ctx = null, .processFn = ButtonOnly.process, .tickFn = null });
    bus.ready.append(testing.allocator, .{ .system = .ready }) catch {};

    var out: [4]TestEvent = undefined;
    const got = try bus.poll(&out, 0);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(TestEvent{ .system = .ready }, got[0]);
}
