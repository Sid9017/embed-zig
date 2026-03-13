//! Timer event source — emits periodic or one-shot timer events via a pipe fd
//! that the event bus can multiplex.
//!
//! Generic over EventType and tag. The EventType's tag payload must be a
//! struct with at least `id: []const u8` and `count: u32` fields.

const std = @import("std");
const event_pkg = struct {
    pub const types = @import("../types.zig");
};
const runtime_channel = @import("../../../runtime/channel.zig");

pub const Mode = enum {
    one_shot,
    repeating,
};

pub const Config = struct {
    id: []const u8 = "timer",
    interval_ms: u32 = 1000,
    mode: Mode = .repeating,
    thread_stack_size: usize = 4096,
};

pub const TimerPayload = struct {
    id: []const u8,
    count: u32,
    interval_ms: u32,
};

pub fn TimerSource(
    comptime Thread: type,
    comptime Time: type,
    comptime ChannelType: type,
    comptime EventType: type,
    comptime tag: []const u8,
) type {
    comptime {
        _ = runtime_channel.from(EventType, ChannelType);
        event_pkg.types.assertTaggedUnion(EventType);
    }

    return struct {
        const Self = @This();

        channel: ChannelType,
        time: Time,
        config: Config,
        worker: ?Thread = null,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        pub fn init(allocator: std.mem.Allocator, time: Time, config: Config) !Self {
            const channel = try ChannelType.init(allocator, 16);

            return .{
                .channel = channel,
                .time = time,
                .config = config,
            };
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            self.channel.deinit();
        }

        pub fn start(self: *Self) !void {
            if (self.running.load(.acquire)) return;
            self.running.store(true, .release);
            self.count.store(0, .release);
            errdefer self.running.store(false, .release);
            self.worker = try Thread.spawn(
                .{ .stack_size = self.config.thread_stack_size },
                workerMain,
                @ptrCast(self),
            );
        }

        pub fn stop(self: *Self) void {
            if (!self.running.swap(false, .acq_rel)) return;
            if (self.worker) |*th| {
                th.join();
                self.worker = null;
            }
        }

        pub fn isRunning(self: *const Self) bool {
            return self.running.load(.acquire);
        }

        fn workerMain(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return));
            while (self.running.load(.acquire)) {
                self.time.sleepMs(self.config.interval_ms);
                if (!self.running.load(.acquire)) break;

                const c = self.count.fetchAdd(1, .monotonic) + 1;
                const event = @unionInit(EventType, tag, .{
                    .id = self.config.id,
                    .count = c,
                    .interval_ms = self.config.interval_ms,
                });
                _ = self.channel.send(event) catch {};

                if (self.config.mode == .one_shot) {
                    self.running.store(false, .release);
                    break;
                }
            }
        }
    };
}
