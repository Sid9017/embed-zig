//! AppRuntime — Unified event → state orchestrator.
//!
//! Combines event.Bus (selector-driven event collection + middleware) with
//! flux.Store (reducer-based state management) into a single tick()-driven
//! loop. Output (LED, display, speaker, etc.) is the caller's responsibility.
//!
//! The user defines an App type with:
//!   pub const State: type
//!   pub const Event: type          (union(enum), shared with Bus)
//!   pub fn reduce(*State, Event) void
//!
//! Usage:
//!   var rt = AppRuntime(MyApp, Selector).init(allocator, &selector, .{});
//!   try rt.register(button.channel);
//!   rt.use(gesture.middleware());
//!   while (running) {
//!       try rt.tick();
//!       if (rt.isDirty()) {
//!           // read rt.getState() / rt.getPrev(), drive any outputs
//!           rt.commitFrame();
//!       }
//!   }

const std = @import("std");
const flux = struct {
    pub fn Store(comptime State: type, comptime EventType: type) type {
        return @import("../flux/store.zig").Store(State, EventType);
    }
};
const event_pkg = struct {
    pub const types = @import("../event/types.zig");

    pub fn Bus(comptime Selector: type, comptime EventType: type) type {
        return @import("../event/bus.zig").Bus(Selector, EventType);
    }

    pub fn Middleware(comptime EventType: type) type {
        return @import("../event/middleware.zig").Middleware(EventType);
    }
};

pub fn AppRuntime(comptime App: type, comptime Selector: type) type {
    comptime {
        _ = @as(type, App.State);
        _ = @as(type, App.Event);
        _ = @as(*const fn (*App.State, App.Event) void, &App.reduce);
    }

    const EventType = App.Event;
    const StoreType = flux.Store(App.State, EventType);
    const BusType = event_pkg.Bus(Selector, EventType);
    const MiddlewareType = event_pkg.Middleware(EventType);

    return struct {
        const Self = @This();

        pub const Config = struct {
            initial_state: App.State = .{},
            poll_timeout_ms: ?u32 = 50,
        };

        store: StoreType,
        bus: BusType,
        poll_timeout_ms: ?u32,

        event_buf: [32]EventType = undefined,

        pub fn init(allocator: std.mem.Allocator, selector: *Selector, config: Config) Self {
            return .{
                .store = StoreType.init(config.initial_state, App.reduce),
                .bus = BusType.init(allocator, selector),
                .poll_timeout_ms = config.poll_timeout_ms,
            };
        }

        pub fn deinit(self: *Self) void {
            self.bus.deinit();
        }

        pub fn register(self: *Self, channel: BusType.Channel) !void {
            try self.bus.register(channel);
        }

        pub fn use(self: *Self, mw: MiddlewareType) void {
            self.bus.use(mw);
        }

        /// Single iteration: poll events → reduce.
        /// Check isDirty() afterwards to decide whether to update outputs.
        pub fn tick(self: *Self) !void {
            const events = try self.bus.poll(&self.event_buf, self.poll_timeout_ms);

            for (events) |ev| {
                self.store.dispatch(ev);
            }
        }

        /// Inject an event directly (bypasses IO/peripherals, goes straight to reducer).
        pub fn inject(self: *Self, ev: EventType) void {
            self.store.dispatch(ev);
        }

        pub fn getState(self: *const Self) *const App.State {
            return self.store.getState();
        }

        pub fn getPrev(self: *const Self) *const App.State {
            return self.store.getPrev();
        }

        pub fn isDirty(self: *const Self) bool {
            return self.store.isDirty();
        }

        /// Mark the current state as consumed. Call after you've driven outputs.
        pub fn commitFrame(self: *Self) void {
            self.store.commitFrame();
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const TestApp = struct {
    pub const State = struct {
        count: u32 = 0,
    };

    pub const Event = union(enum) {
        tick,
        increment,
    };

    pub fn reduce(state: *State, ev: Event) void {
        switch (ev) {
            .tick => {},
            .increment => state.count += 1,
        }
    }
};

const TestChannel = struct {
    id: u8,

    pub fn isSelectable() void {}
};

const TestSelector = struct {
    watched_count: usize = 0,

    pub const channel_t = TestChannel;
    pub const event_t = TestApp.Event;

    pub fn init(_: std.mem.Allocator) !@This() {
        return .{};
    }

    pub fn deinit(_: *@This()) void {}

    pub fn add(self: *@This(), _: TestChannel) !void {
        self.watched_count += 1;
    }

    pub fn remove(self: *@This(), _: TestChannel) !void {
        if (self.watched_count > 0) self.watched_count -= 1;
    }

    pub fn poll(_: *@This(), _: ?u32) !?TestApp.Event {
        return null;
    }
};

test "AppRuntime: inject dispatches to reducer" {
    var selector = try TestSelector.init(testing.allocator);
    defer selector.deinit();

    var rt = AppRuntime(TestApp, TestSelector).init(
        testing.allocator,
        &selector,
        .{ .poll_timeout_ms = 0 },
    );
    defer rt.deinit();

    rt.inject(.increment);
    try testing.expectEqual(@as(u32, 1), rt.getState().count);
    try testing.expect(rt.isDirty());

    rt.commitFrame();
    try testing.expect(!rt.isDirty());
}

test "AppRuntime: tick with no events does not re-dirty" {
    var selector = try TestSelector.init(testing.allocator);
    defer selector.deinit();

    var rt = AppRuntime(TestApp, TestSelector).init(
        testing.allocator,
        &selector,
        .{ .poll_timeout_ms = 0 },
    );
    defer rt.deinit();

    rt.commitFrame();
    try testing.expect(!rt.isDirty());

    try rt.tick();
    try testing.expect(!rt.isDirty());
}

test "AppRuntime: commitFrame resets dirty" {
    var selector = try TestSelector.init(testing.allocator);
    defer selector.deinit();

    var rt = AppRuntime(TestApp, TestSelector).init(
        testing.allocator,
        &selector,
        .{ .poll_timeout_ms = 0 },
    );
    defer rt.deinit();

    rt.inject(.increment);
    try testing.expect(rt.isDirty());
    try testing.expectEqual(@as(u32, 1), rt.getState().count);

    rt.commitFrame();
    try testing.expect(!rt.isDirty());

    rt.inject(.increment);
    try testing.expect(rt.isDirty());
    try testing.expectEqual(@as(u32, 2), rt.getState().count);
}
