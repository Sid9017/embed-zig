const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const types = embed.pkg.event.motion.motion_types;

// ============================================================================
// Tests
// ============================================================================

test "AccelData magnitude" {
    const data = types.AccelData{ .x = 0, .y = 0, .z = 1.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), data.magnitude(), 0.001);

    const data2 = types.AccelData{ .x = 1.0, .y = 1.0, .z = 1.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.732), data2.magnitude(), 0.01);
}

test "MotionAction with gyro" {
    const Action = types.MotionAction(true);
    const shake = Action{ .shake = .{ .magnitude = 2.5, .duration_ms = 100 } };
    try std.testing.expectEqual(@as(f32, 2.5), shake.shake.magnitude);

    // Flip should be available with gyro
    const flip = Action{ .flip = .{ .from = .face_up, .to = .face_down } };
    try std.testing.expectEqual(types.Orientation.face_up, flip.flip.from);
}

test "MotionAction without gyro" {
    const Action = types.MotionAction(false);
    const shake = Action{ .shake = .{ .magnitude = 2.5, .duration_ms = 100 } };
    try std.testing.expectEqual(@as(f32, 2.5), shake.shake.magnitude);

    // Flip field exists but is void type
    _ = Action{ .flip = {} };
}

test "SensorSample with gyro" {
    const Sample = types.SensorSample(true);
    const s = Sample{
        .accel = .{ .x = 0, .y = 0, .z = 1.0 },
        .gyro = .{ .x = 0, .y = 0, .z = 0 },
        .timestamp_ms = 100,
    };
    try std.testing.expectEqual(@as(f32, 1.0), s.accel.z);
}

test "SensorSample without gyro" {
    const Sample = types.SensorSample(false);
    const s = Sample{
        .accel = .{ .x = 0, .y = 0, .z = 1.0 },
        .gyro = {},
        .timestamp_ms = 100,
    };
    try std.testing.expectEqual(@as(f32, 1.0), s.accel.z);
}
