//! Motion peripheral — polls an IMU, runs the Detector algorithm, and
//! injects detected motion actions (shake, tap, tilt, flip, freefall)
//! into the event bus via EventInjector.
//!
//! The caller is responsible for running the polling loop. Call `run()`
//! from a dedicated thread/task; call `stop()` to exit the loop.

const std = @import("std");
const hal = struct {
    pub const imu = @import("../../../hal/imu.zig");
};
const bus_mod = @import("../bus.zig");
const detector_mod = @import("detector.zig");
const motion_types = @import("types.zig");

pub const Config = struct {
    id: []const u8 = "imu",
    poll_interval_ms: u32 = 20,
    thresholds: motion_types.Thresholds = .{},
};

pub fn MotionPeripheral(
    comptime Sensor: type,
    comptime Time: type,
) type {
    comptime {
        if (!hal.imu.is(Sensor)) @compileError("Sensor must be a hal.imu type");
    }
    const Det = detector_mod.Detector(Sensor);
    const Action = Det.ActionType;
    const Sample = Det.SampleType;
    const Injector = bus_mod.EventInjector(Action);

    return struct {
        const Self = @This();

        pub const Event = Action;

        sensor: *Sensor,
        time: Time,
        config: Config,
        injector: Injector,
        detector: Det,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn init(sensor: *Sensor, time: Time, config: Config, injector: Injector) Self {
            return .{
                .sensor = sensor,
                .time = time,
                .config = config,
                .injector = injector,
                .detector = Det.init(config.thresholds),
            };
        }

        pub fn run(self: *Self) void {
            self.running.store(true, .release);
            defer self.running.store(false, .release);

            while (self.running.load(.acquire)) {
                self.tick();
                self.time.sleepMs(self.config.poll_interval_ms);
            }
        }

        pub fn runFromCtx(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return));
            self.run();
        }

        pub fn stop(self: *Self) void {
            self.running.store(false, .release);
        }

        pub fn isRunning(self: *const Self) bool {
            return self.running.load(.acquire);
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
                self.injector.invoke(action);
            }
            while (self.detector.nextEvent()) |action| {
                self.injector.invoke(action);
            }
        }
    };
}
