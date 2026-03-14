//! Unified audio system HAL contract.
//!
//! Models mic capture + speaker-reference + speaker output as a single
//! coordinated subsystem.  The driver owns the entire audio pipeline:
//!
//!   - `readFrame` returns all mic channels **and** a mandatory ref channel.
//!   - `writeSpk` pushes samples to the speaker.
//!   - Per-mic gain is set via `setMicGain(index, dB)`.
//!   - Speaker gain is set via `setSpkGain(dB)`; the driver automatically
//!     derives the ref gain from the speaker gain.
//!   - Ref-to-mic time alignment is the driver's responsibility.

const hal_marker = @import("marker.zig");

pub const Error = error{
    WouldBlock,
    Timeout,
    Overflow,
    InvalidState,
    AudioSystemError,
};

pub const Config = struct {
    sample_rate: u32 = 16000,
    mic_count: u8 = 1,
};

pub fn Frame(comptime mic_count: u8) type {
    return struct {
        mic: [mic_count][]const i16,
        ref: []const i16,
    };
}

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .audio_system;
}

/// spec must define:
///   - Driver          — concrete driver type
///   - meta.id         — []const u8 identifier
///   - config          — Config (sample_rate > 0, mic_count > 0)
///
/// Driver must implement:
///   - readFrame(*Driver) Error!Frame(config.mic_count)
///   - writeSpk(*Driver, []const i16) Error!usize
///   - setMicGain(*Driver, u8, i8) Error!void
///   - setSpkGain(*Driver, i8) Error!void
///   - start(*Driver) Error!void
///   - stop(*Driver) Error!void
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };

    const cfg: Config = comptime if (@hasDecl(spec, "config")) spec.config else .{};
    const FrameType = Frame(cfg.mic_count);

    comptime {
        if (cfg.sample_rate == 0) {
            @compileError("audio_system config.sample_rate must be > 0");
        }
        if (cfg.mic_count == 0) {
            @compileError("audio_system config.mic_count must be > 0");
        }

        _ = @as(*const fn (*BaseDriver) Error!FrameType, &BaseDriver.readFrame);
        _ = @as(*const fn (*BaseDriver, []const i16) Error!usize, &BaseDriver.writeSpk);
        _ = @as(*const fn (*BaseDriver, u8, i8) Error!void, &BaseDriver.setMicGain);
        _ = @as(*const fn (*BaseDriver, i8) Error!void, &BaseDriver.setSpkGain);
        _ = @as(*const fn (*BaseDriver) Error!void, &BaseDriver.start);
        _ = @as(*const fn (*BaseDriver) Error!void, &BaseDriver.stop);

        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .audio_system,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;
        pub const config: Config = cfg;
        pub const FrameT = FrameType;

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn readFrame(self: *Self) Error!FrameT {
            return self.driver.readFrame();
        }

        pub fn writeSpk(self: *Self, buffer: []const i16) Error!usize {
            return self.driver.writeSpk(buffer);
        }

        pub fn setMicGain(self: *Self, mic_index: u8, gain_db: i8) Error!void {
            return self.driver.setMicGain(mic_index, gain_db);
        }

        pub fn setSpkGain(self: *Self, gain_db: i8) Error!void {
            return self.driver.setSpkGain(gain_db);
        }

        pub fn start(self: *Self) Error!void {
            return self.driver.start();
        }

        pub fn stop(self: *Self) Error!void {
            return self.driver.stop();
        }

        pub fn samplesForMs(duration_ms: u32) u32 {
            return cfg.sample_rate * duration_ms / 1000;
        }

        pub fn msForSamples(samples: u32) u32 {
            return samples * 1000 / cfg.sample_rate;
        }
    };
}
