//! Motion peripheral — polls an IMU via a worker thread, runs the Detector
//! algorithm, and writes detected motion actions (shake, tap, tilt, flip,
//! freefall) to a pipe fd that the event bus can multiplex.
//!
//! Generic over EventType and tag. The EventType's tag payload must be
//! compatible with the Detector's ActionType (MotionAction).

const std = @import("std");
const hal = struct {
    pub const imu = @import("../../../hal/imu.zig");
};
const event_pkg = struct {
    pub const types = @import("../types.zig");
};
const runtime_pkg = struct {
    pub const channel = @import("../../../runtime/channel.zig");
};
const detector_mod = @import("detector.zig");
const motion_types = @import("types.zig");

pub const Config = struct {
    id: []const u8 = "imu",
    poll_interval_ms: u32 = 20,
    thread_stack_size: usize = 4096,
    thresholds: motion_types.Thresholds = .{},
};

pub fn MotionPeripheral(
    comptime Sensor: type,
    comptime Thread: type,
    comptime Time: type,
    comptime ChannelType: type,
    comptime EventType: type,
    comptime tag: []const u8,
) type {
    comptime {
        if (!hal.imu.is(Sensor)) @compileError("Sensor must be a hal.imu type");
        _ = runtime_pkg.channel.from(EventType, ChannelType);
        event_pkg.types.assertTaggedUnion(EventType);
    }
    const Det = detector_mod.Detector(Sensor);
    const Action = Det.ActionType;
    const Sample = Det.SampleType;

    return struct {
        const Self = @This();

        channel: ChannelType,
        sensor: *Sensor,
        time: Time,
        config: Config,
        detector: Det,
        worker: ?Thread = null,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn init(allocator: std.mem.Allocator, sensor: *Sensor, time: Time, config: Config) !Self {
            const channel = try ChannelType.init(allocator, 16);

            return .{
                .channel = channel,
                .sensor = sensor,
                .time = time,
                .config = config,
                .detector = Det.init(config.thresholds),
            };
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            self.channel.deinit();
        }

        pub fn start(self: *Self) !void {
            if (self.running.load(.acquire)) return;
            self.running.store(true, .release);
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
                self.tick();
                self.time.sleepMs(self.config.poll_interval_ms);
            }
        }

        fn tick(self: *Self) void {
            const accel_raw = self.sensor.readAccel() catch return;
            const accel = motion_types.accelFrom(accel_raw);

            const gyro = if (Det.has_gyroscope)
                motion_types.gyroFrom(self.sensor.readGyro() catch return)
            else {};

            const sample = Sample{
                .accel = accel,
                .gyro = gyro,
                .timestamp_ms = self.time.nowMs(),
            };

            if (self.detector.update(sample)) |action| {
                self.writeAction(action);
            }
            while (self.detector.nextEvent()) |action| {
                self.writeAction(action);
            }
        }

        fn writeAction(self: *Self, action: Action) void {
            const event = @unionInit(EventType, tag, action);
            _ = self.channel.send(event) catch {};
        }
    };
}
