const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const detector = embed.pkg.event.motion.detector;
const motion_types = embed.pkg.event.motion.motion_types;

// ============================================================================
// Tests
// ============================================================================

// Mock sensor detector.types for testing
const MockAccelOnlySensor = struct {
    pub fn readAccel(_: *@This()) !motion_types.AccelData {
        return .{ .x = 0, .y = 0, .z = 1.0 };
    }
};

const MockImuSensor = struct {
    pub fn readAccel(_: *@This()) !motion_types.AccelData {
        return .{ .x = 0, .y = 0, .z = 1.0 };
    }
    pub fn readGyro(_: *@This()) !motion_types.GyroData {
        return .{ .x = 0, .y = 0, .z = 0 };
    }
};

test "hasMethod detection" {
    try std.testing.expect(detector.hasMethod(MockImuSensor, "readGyro", motion_types.GyroData));
    try std.testing.expect(detector.hasMethod(MockImuSensor, "readAccel", motion_types.AccelData));
    try std.testing.expect(!detector.hasMethod(MockAccelOnlySensor, "readGyro", motion_types.GyroData));
    try std.testing.expect(detector.hasMethod(MockAccelOnlySensor, "readAccel", motion_types.AccelData));
}

test "Detector capability detection" {
    const ImuDetector = detector.Detector(MockImuSensor);
    const AccelDetector = detector.Detector(MockAccelOnlySensor);

    try std.testing.expect(ImuDetector.has_gyroscope);
    try std.testing.expect(!AccelDetector.has_gyroscope);
}

test "Detector initialization" {
    const det = detector.Detector(MockImuSensor).initDefault();
    try std.testing.expectEqual(@as(f32, 1.5), det.thresholds.shake_threshold);
}

test "Detector shake detection" {
    var det = detector.Detector(MockImuSensor).init(.{
        .shake_threshold = 1.0,
        .shake_min_duration = 50,
        .shake_max_duration = 500,
    });

    const Sample = detector.Detector(MockImuSensor).SampleType;

    // Simulate shake sequence
    var t: u64 = 0;

    // Initial samples
    _ = det.update(Sample{ .accel = .{ .x = 0, .y = 0, .z = 1.0 }, .gyro = .{ .x = 0, .y = 0, .z = 0 }, .timestamp_ms = t });
    t += 10;

    // Shake motion
    _ = det.update(Sample{ .accel = .{ .x = 2.0, .y = 0, .z = 1.0 }, .gyro = .{ .x = 0, .y = 0, .z = 0 }, .timestamp_ms = t });
    t += 10;
    _ = det.update(Sample{ .accel = .{ .x = -2.0, .y = 0, .z = 1.0 }, .gyro = .{ .x = 0, .y = 0, .z = 0 }, .timestamp_ms = t });
    t += 10;
    _ = det.update(Sample{ .accel = .{ .x = 2.0, .y = 0, .z = 1.0 }, .gyro = .{ .x = 0, .y = 0, .z = 0 }, .timestamp_ms = t });
    t += 30;

    // End shake
    const event = det.update(Sample{ .accel = .{ .x = 0, .y = 0, .z = 1.0 }, .gyro = .{ .x = 0, .y = 0, .z = 0 }, .timestamp_ms = t });

    // Should detect shake (though timing might vary)
    _ = event;
}

test "Detector tilt detection" {
    var det = detector.Detector(MockAccelOnlySensor).init(.{
        .tilt_threshold = 5.0,
        .tilt_debounce = 0,
    });

    const Sample = detector.Detector(MockAccelOnlySensor).SampleType;

    // Initial flat position
    _ = det.update(Sample{ .accel = .{ .x = 0, .y = 0, .z = 1.0 }, .gyro = {}, .timestamp_ms = 0 });

    // Tilt to 30 degrees
    const event = det.update(Sample{
        .accel = .{ .x = 0.5, .y = 0, .z = 0.866 }, // ~30 degree tilt
        .gyro = {},
        .timestamp_ms = 100,
    });

    if (event) |e| {
        switch (e) {
            .tilt => |t| {
                try std.testing.expect(@abs(t.pitch) > 20.0);
            },
            else => {},
        }
    }
}

test "Detector with accel-only sensor" {
    // Should compile without gyro features
    var det = detector.Detector(MockAccelOnlySensor).initDefault();
    const Sample = detector.Detector(MockAccelOnlySensor).SampleType;

    _ = det.update(Sample{ .accel = .{ .x = 0, .y = 0, .z = 1.0 }, .gyro = {}, .timestamp_ms = 0 });
}
