//! AppStateManager — Event dispatch + frame-rate controlled render scheduling
//!
//! Manages the complete app lifecycle:
//!   1. Receives events from any source (buttons, BLE, timers)
//!   2. Dispatches to reducer (single source of truth)
//!   3. Schedules render at configured fps (only when state changed)
//!
//! Usage:
//!   var app = AppStateManager(MyApp).init(.{
//!       .fps = 30,
//!   });
//!   app.dispatch(.{ .input = .{ .id = .left, .action = .click } });
//!   // In task loop:
//!   app.tick(now_ms); // checks dirty + frame interval → calls render if needed
//!
//! App must provide:
//!   pub const State: type           — AppState struct
//!   pub const Event: type           — AppEvent union(enum)
//!   pub fn reduce(*State, Event) void
//!   pub fn render(*Framebuffer, *const State, *const Resources) void
//!   pub const Resources: type       — immutable resources struct

const Store = @import("store.zig").Store;

pub fn AppStateManager(comptime App: type) type {
    comptime {
        _ = @as(type, App.State);
        _ = @as(type, App.Event);
        _ = @as(*const fn (*App.State, App.Event) void, &App.reduce);
    }

    return struct {
        const Self = @This();

        store: Store(App.State, App.Event),
        last_render_ms: u64 = 0,
        rendered_once: bool = false,
        min_frame_interval_ms: u32,
        fps: u8,

        pub const Config = struct {
            fps: u8 = 30,
            initial_state: App.State = .{},
        };

        pub fn init(config: Config) Self {
            return .{
                .store = Store(App.State, App.Event).init(config.initial_state, App.reduce),
                .min_frame_interval_ms = if (config.fps == 0) 0 else 1000 / @as(u32, config.fps),
                .fps = config.fps,
            };
        }

        /// Dispatch an event — calls reducer, marks dirty if state changed.
        /// Can be called from any thread/context (button callback, BLE, timer).
        pub fn dispatch(self: *Self, event: App.Event) void {
            self.store.dispatch(event);
        }

        /// Dispatch multiple events at once.
        pub fn dispatchBatch(self: *Self, events: []const App.Event) void {
            self.store.dispatchBatch(events);
        }

        /// Check if render is needed and enough time has passed.
        /// Call this in the UI task loop. Returns true if render was performed.
        /// Caller is responsible for actually calling render and flushing display.
        pub fn shouldRender(self: *Self, now_ms: u64) bool {
            if (!self.store.isDirty()) return false;
            if (self.fps == 0) return true; // unlimited fps
            if (!self.rendered_once) return true; // first frame always renders
            if (now_ms - self.last_render_ms < @as(u64, self.min_frame_interval_ms)) return false;
            return true;
        }

        /// Mark render as done. Call after render + flush completes.
        pub fn commitFrame(self: *Self, now_ms: u64) void {
            self.store.commitFrame();
            self.last_render_ms = now_ms;
            self.rendered_once = true;
        }

        /// Get current state (read-only, for rendering).
        pub fn getState(self: *const Self) *const App.State {
            return self.store.getState();
        }

        /// Get previous frame state (read-only, for diff rendering).
        pub fn getPrev(self: *const Self) *const App.State {
            return self.store.getPrev();
        }

        /// Check if state has changed since last commitFrame.
        pub fn isDirty(self: *const Self) bool {
            return self.store.isDirty();
        }
    };
}
