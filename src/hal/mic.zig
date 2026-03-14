//! Microphone HAL wrapper.

const hal_marker = @import("marker.zig");

pub const Error = error{
    WouldBlock,
    Timeout,
    Overflow,
    InvalidState,
    MicError,
};

pub const SampleFormat = enum {
    s16,
    s32,
    f32,
};

pub const Config = struct {
    sample_rate: u32 = 16000,
    channels: u8 = 1,
    bits_per_sample: u8 = 16,
};

/// One capture frame used by audio-engine style pipelines.
///
/// - `mic_matrix[i]` is the i-th microphone channel frame
/// - `ref` is optional speaker-reference frame for AEC
pub const Frame = struct {
    mic_matrix: []const []const i16,
    ref: ?[]const i16 = null,
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .mic;
}

/// spec must define:
/// - Driver.read(*Driver, []i16) !usize
/// - meta.id: []const u8
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };

    const has_spec_config = comptime @hasDecl(spec, "config");
    const has_frame_read = comptime @hasDecl(BaseDriver, "readFrame");

    comptime {
        _ = @as(*const fn (*BaseDriver, []i16) Error!usize, &BaseDriver.read);
        _ = @as(*const fn (*BaseDriver, i8) Error!void, &BaseDriver.setGain);
        _ = @as(*const fn (*BaseDriver) Error!void, &BaseDriver.start);
        _ = @as(*const fn (*BaseDriver) Error!void, &BaseDriver.stop);
        if (has_frame_read) {
            _ = @as(*const fn (*BaseDriver) Error!?Frame, &BaseDriver.readFrame);
        }

        _ = @as([]const u8, spec.meta.id);
        if (has_spec_config) {
            _ = @as(Config, spec.config);
            if (spec.config.sample_rate == 0) {
                @compileError("mic config.sample_rate must be > 0");
            }
        }
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .mic,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;
        pub const config: Config = if (has_spec_config) spec.config else .{};

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn read(self: *Self, buffer: []i16) Error!usize {
            return self.driver.read(buffer);
        }

        /// Read one matrix frame + optional reference frame.
        ///
        /// Returns:
        /// - `null` when no frame is currently available (non-blocking path)
        /// - `Frame` when one aligned frame is available
        ///
        /// If the driver does not implement `readFrame`, returns `error.InvalidState`.
        pub fn readFrame(self: *Self) Error!?Frame {
            if (comptime has_frame_read) {
                return self.driver.readFrame();
            }
            return error.InvalidState;
        }

        pub fn setGain(self: *Self, gain_db: i8) Error!void {
            return self.driver.setGain(gain_db);
        }

        pub fn start(self: *Self) Error!void {
            return self.driver.start();
        }

        pub fn stop(self: *Self) Error!void {
            return self.driver.stop();
        }

        pub fn supportsGain() bool {
            return true;
        }

        pub fn supportsStartStop() bool {
            return true;
        }

        pub fn supportsFrameRead() bool {
            return has_frame_read;
        }

        pub fn samplesForMs(duration_ms: u32) u32 {
            return config.sample_rate * duration_ms / 1000;
        }

        pub fn msForSamples(samples: u32) u32 {
            return samples * 1000 / config.sample_rate;
        }
    };
}
