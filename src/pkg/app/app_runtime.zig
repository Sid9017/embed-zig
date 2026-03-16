//! AppRuntime — Unified event → state orchestrator.
//!
//! Combines event.Bus (channel + middleware + background task) with
//! flux.Store (reducer-based state management) into a single loop.
//! Output (LED, display, speaker, etc.) is the caller's responsibility.
//!
//! The user defines an App type with:
//!   pub const State: type
//!   pub const InputSpec: comptime struct   (bus input spec)
//!   pub const OutputSpec: comptime struct  (bus output spec)
//!   pub fn reduce(*State, BusEvent) void
//!
//! Usage:
//!   var rt = try AppRuntime(MyApp, ChannelFactory).init(alloc, 64, .{});
//!   bus.use(gesture_mw);
//!   // spawn rt.bus.run() in a thread
//!   while (true) {
//!       const r = try rt.recv();
//!       if (!r.ok) break;
//!       rt.dispatch(r.value);
//!       if (rt.isDirty()) { ... render ...; rt.commitFrame(); }
//!   }

const std = @import("std");
const bus_mod = @import("../event/bus.zig");
const flux_store = @import("../flux/store.zig");

pub fn AppRuntime(
    comptime App: type,
    comptime ChannelFactory: type,
) type {
    const BusType = bus_mod.Bus(App.InputSpec, App.OutputSpec, ChannelFactory);
    const StoreType = flux_store.Store(App.State, BusType.BusEvent);

    comptime {
        _ = @as(type, App.State);
        _ = @as(*const fn (*App.State, BusType.BusEvent) void, &App.reduce);
    }

    return struct {
        const Self = @This();

        pub const BusEvent = BusType.BusEvent;
        pub const InputEvent = BusType.InputEvent;
        pub const InputEventTag = BusType.InputEventTag;
        pub const RecvResult = BusType.RecvResult;
        pub const SendResult = BusType.SendResult;

        pub const Config = struct {
            initial_state: App.State = .{},
        };

        store: StoreType,
        bus: BusType,

        pub fn init(allocator: std.mem.Allocator, capacity: usize, config: Config) !Self {
            return .{
                .store = StoreType.init(config.initial_state, App.reduce),
                .bus = try BusType.init(allocator, capacity),
            };
        }

        pub fn deinit(self: *Self) void {
            self.bus.deinit();
        }

        pub fn inject(self: *Self, comptime tag: InputEventTag, payload: std.meta.TagPayload(InputEvent, tag)) !SendResult {
            return try self.bus.inject(tag, payload);
        }

        pub fn use(self: *Self, mw: anytype) void {
            self.bus.use(mw);
        }

        pub fn recv(self: *Self) !RecvResult {
            return try self.bus.recv();
        }

        pub fn dispatch(self: *Self, ev: BusEvent) void {
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

        pub fn commitFrame(self: *Self) void {
            self.store.commitFrame();
        }
    };
}
