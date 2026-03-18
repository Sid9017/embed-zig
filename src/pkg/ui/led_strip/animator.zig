const std = @import("std");
const frame_mod = @import("frame.zig");
const transition = @import("transition.zig");

const Color = frame_mod.Color;

/// Multi-frame LED strip animator with inter-frame transitions.
///
/// `n` — number of LEDs.
/// `max_frames` — maximum animation frames (comptime).
///
/// The animator holds a sequence of target frames. Each tick:
///   1. Advance frame index when interval_ticks is reached.
///   2. Lerp `current` toward the active target frame.
///
/// `current` always holds the actual output to flush to hardware.
pub fn Animator(comptime n: u32, comptime max_frames: u32) type {
    const FrameType = frame_mod.Frame(n);

    return struct {
        const Self = @This();
        pub const pixel_count = n;
        pub const Frame = FrameType;

        frames: [max_frames]FrameType = [_]FrameType{.{}} ** max_frames,
        total_frames: u8 = 0,
        current_frame: u8 = 0,
        interval_ticks: u8 = 16,
        tick_count: u8 = 0,
        step_amount: u8 = 5,

        current: FrameType = .{},
        brightness: u8 = 255,

        /// Advance animation by one tick. Returns true if `current` changed.
        pub fn tick(self: *Self) bool {
            if (self.total_frames == 0) return false;

            self.tick_count += 1;
            if (self.tick_count >= self.interval_ticks) {
                self.tick_count = 0;
                self.current_frame = (self.current_frame + 1) % self.total_frames;
            }

            var target = self.frames[self.current_frame];
            if (self.brightness < 255) {
                target = target.withBrightness(self.brightness);
            }

            return transition.stepFrame(n, &self.current, target, self.step_amount);
        }

        // ----------------------------------------------------------------
        // Preset constructors
        // ----------------------------------------------------------------

        /// Static: transition to a single frame and hold.
        pub fn fixed(f: FrameType) Self {
            var self = Self{};
            self.frames[0] = f;
            self.total_frames = 1;
            self.interval_ticks = 16;
            return self;
        }

        /// Flash: alternate between frame and black.
        pub fn flash(f: FrameType, interval: u8) Self {
            var self = Self{};
            self.frames[0] = f;
            self.frames[1] = .{};
            self.total_frames = 2;
            self.interval_ticks = interval;
            return self;
        }

        /// Ping-pong between two frames.
        pub fn pingpong(from: FrameType, to: FrameType, interval: u8) Self {
            var self = Self{};
            self.frames[0] = from;
            self.frames[1] = to;
            self.total_frames = 2;
            self.interval_ticks = interval;
            return self;
        }

        /// Rotate: generate N rotated versions of a frame.
        pub fn rotateAnim(f: FrameType, interval: u8) Self {
            var self = Self{};
            const count = @min(n, max_frames);
            self.frames[0] = f;
            for (1..count) |i| {
                self.frames[i] = self.frames[i - 1].rotate();
            }
            self.total_frames = @intCast(count);
            self.interval_ticks = interval;
            return self;
        }
    };
}
