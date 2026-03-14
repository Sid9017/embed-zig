//! Mono speaker HAL wrapper.

const hal_marker = @import("marker.zig");

pub const Error = error{
    WouldBlock,
    Timeout,
    Overflow,
    InvalidState,
    SpeakerError,
};

pub const Config = struct {
    sample_rate: u32 = 16000,
    bits_per_sample: u8 = 16,
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .speaker;
}

/// spec must define:
/// - Driver.write(*Driver, []const i16) !usize
/// - meta.id: []const u8
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };
    const has_spec_config = comptime @hasDecl(spec, "config");

    comptime {
        _ = @as(*const fn (*BaseDriver, []const i16) Error!usize, &BaseDriver.write);
        _ = @as(*const fn (*BaseDriver, u8) Error!void, &BaseDriver.setVolume);
        _ = @as(*const fn (*BaseDriver, bool) Error!void, &BaseDriver.setMute);
        _ = @as([]const u8, spec.meta.id);
        if (has_spec_config) {
            _ = @as(Config, spec.config);
            if (spec.config.sample_rate == 0) {
                @compileError("speaker config.sample_rate must be > 0");
            }
        }
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .speaker,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;
        pub const config: Config = if (has_spec_config) spec.config else .{};

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn write(self: *Self, buffer: []const i16) Error!usize {
            return self.driver.write(buffer);
        }

        pub fn setVolume(self: *Self, volume: u8) Error!void {
            return self.driver.setVolume(volume);
        }

        pub fn setMute(self: *Self, mute: bool) Error!void {
            return self.driver.setMute(mute);
        }

        pub fn supportsVolume() bool {
            return true;
        }

        pub fn supportsMute() bool {
            return true;
        }

        pub fn samplesForMs(duration_ms: u32) u32 {
            return config.sample_rate * duration_ms / 1000;
        }

        pub fn msForSamples(samples: u32) u32 {
            return samples * 1000 / config.sample_rate;
        }
    };
}
