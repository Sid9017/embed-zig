//! Audio resampling and channel conversion helpers.

const std = @import("std");
const embed = @import("../../mod.zig");
const speexdsp = embed.third_party.speexdsp;

pub const Format = struct {
    rate: u32,
    channels: Channels = .mono,

    pub const Channels = enum(u2) {
        mono = 1,
        stereo = 2,
    };

    pub fn channelCount(self: Format) u32 {
        return @intFromEnum(self.channels);
    }

    pub fn sampleBytes(self: Format) usize {
        return @as(usize, @intFromEnum(self.channels)) * @sizeOf(i16);
    }

    pub fn eql(a: Format, b: Format) bool {
        return a.rate == b.rate and a.channels == b.channels;
    }
};

pub fn stereoToMono(buf: []i16) usize {
    const frames = buf.len / 2;
    for (0..frames) |i| {
        const l: i32 = buf[i * 2];
        const r: i32 = buf[i * 2 + 1];
        buf[i] = @intCast(@divTrunc(l + r, 2));
    }
    return frames;
}

pub fn monoToStereo(input: []const i16, output: []i16) usize {
    const n = @min(input.len, output.len / 2);
    var i = n;
    while (i > 0) {
        i -= 1;
        output[i * 2] = input[i];
        output[i * 2 + 1] = input[i];
    }
    return n;
}

pub const Resampler = struct {
    inner: speexdsp.Resampler,
    channels: u32,
    in_rate: u32,
    out_rate: u32,

    pub const Config = struct {
        channels: u32 = 1,
        in_rate: u32,
        out_rate: u32,
        quality: u4 = 3,
    };

    pub const Result = struct {
        in_consumed: u32,
        out_produced: u32,
    };

    pub fn init(_: std.mem.Allocator, config: Config) !Resampler {
        if (config.channels == 0) return error.InvalidChannels;
        if (config.in_rate == 0 or config.out_rate == 0) return error.InvalidRate;

        const inner = try speexdsp.Resampler.init(
            config.channels,
            config.in_rate,
            config.out_rate,
            @as(c_int, @intCast(config.quality)),
        );
        return .{ .inner = inner, .channels = config.channels, .in_rate = config.in_rate, .out_rate = config.out_rate };
    }

    pub fn deinit(self: *Resampler) void {
        self.inner.deinit();
    }

    pub fn reset(self: *Resampler) void {
        self.inner.reset() catch {};
    }

    pub fn process(self: *Resampler, in_buf: []const i16, out_buf: []i16) !Result {
        const ch: usize = @intCast(self.channels);
        if (ch == 0) return error.InvalidChannels;
        if (in_buf.len == 0 or out_buf.len == 0) return .{ .in_consumed = 0, .out_produced = 0 };

        if (self.in_rate == self.out_rate) {
            const in_frames = in_buf.len / ch;
            const out_frames_cap = out_buf.len / ch;
            const copy_samples = @min(in_frames, out_frames_cap) * ch;
            @memcpy(out_buf[0..copy_samples], in_buf[0..copy_samples]);
            return .{ .in_consumed = @intCast(copy_samples), .out_produced = @intCast(copy_samples) };
        }

        const res = try self.inner.processInterleavedInt(in_buf, out_buf);
        return .{ .in_consumed = res.in_consumed, .out_produced = res.out_written };
    }
};
