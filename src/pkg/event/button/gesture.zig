//! Button gesture recognizer — click (with consecutive count) and long-press
//! from raw press/release events.
//!
//! Input:  button.RawEvent (press/release)
//! Output: button.GestureEvent (id + click/long_press) via yield callback
//!
//! Conforms to Bus.Processor Impl contract. Usage:
//!
//!   const Gesture = ButtonGesture(Time, .{ .long_press_ms = 500 });
//!   const gp = try MyBus.Processor(.btn_boot, .gesture, Gesture).init(allocator);
//!   defer gp.deinit();
//!   bus.use(gp);

const button_event = @import("event.zig");
const embed = @import("../../../mod.zig");

const RawEvent = button_event.RawEvent;
const RawEventCode = button_event.RawEventCode;
const GestureEvent = button_event.GestureEvent;

pub const GestureConfig = struct {
    long_press_ms: u64 = 500,
    multi_click_window_ms: u64 = 300,
};

pub fn ButtonGesture(comptime Runtime: type, comptime config: GestureConfig) type {
    comptime _ = embed.runtime.is(Runtime);

    return struct {
        const Self = @This();
        const YieldFn = *const fn (?*anyopaque, GestureEvent) void;

        time: Runtime.Time,
        current_id: []const u8 = "",
        pending_press: ?PendingPress = null,
        pending_clicks: ?PendingClicks = null,

        pub fn init() Self {
            return .{ .time = .{} };
        }

        pub fn deinit(_: *Self) void {}

        pub fn process(self: *Self, ev: RawEvent, yield_ctx: ?*anyopaque, yield: YieldFn) void {
            self.current_id = ev.id;
            switch (ev.code) {
                .press => self.onPress(),
                .release => self.onRelease(yield_ctx, yield),
            }
        }

        pub fn tick(self: *Self, yield_ctx: ?*anyopaque, yield: YieldFn) void {
            const now = self.time.nowMs();

            if (self.pending_press) |pp| {
                if (now >= pp.press_ms + config.long_press_ms) {
                    yield(yield_ctx, .{
                        .id = self.current_id,
                        .gesture = .{ .long_press = @intCast(now -| pp.press_ms) },
                    });
                    self.pending_press = null;
                    self.pending_clicks = null;
                }
            }

            if (self.pending_clicks) |pc| {
                if (now >= pc.last_click_ms + config.multi_click_window_ms) {
                    yield(yield_ctx, .{
                        .id = pc.id,
                        .gesture = .{ .click = pc.count },
                    });
                    self.pending_clicks = null;
                }
            }
        }

        // --- private types ---

        const PendingPress = struct {
            press_ms: u64,
        };

        const PendingClicks = struct {
            id: []const u8,
            last_click_ms: u64,
            count: u16,
        };

        // --- private methods ---

        fn onPress(self: *Self) void {
            const now = self.time.nowMs();
            self.pending_press = .{ .press_ms = now };
        }

        fn onRelease(self: *Self, yield_ctx: ?*anyopaque, yield: YieldFn) void {
            const now = self.time.nowMs();

            const pp = self.pending_press orelse return;
            const hold_ms = now -| pp.press_ms;
            self.pending_press = null;

            if (hold_ms >= config.long_press_ms) {
                yield(yield_ctx, .{
                    .id = self.current_id,
                    .gesture = .{ .long_press = @intCast(hold_ms) },
                });
                self.pending_clicks = null;
                return;
            }

            if (self.pending_clicks) |*pc| {
                if (now -| pc.last_click_ms < config.multi_click_window_ms) {
                    pc.count += 1;
                    pc.last_click_ms = now;
                    return;
                }
            }

            self.pending_clicks = .{
                .id = self.current_id,
                .last_click_ms = now,
                .count = 1,
            };
        }
    };
}
