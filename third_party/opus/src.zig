//! Zig bindings for libopus.
//!
//! This package exposes a Zig-first API (Encoder/Decoder + typed enums/errors),
//! while internally calling libopus C APIs.

const std = @import("std");
const c = @cImport({
    @cInclude("opus.h");
});

pub const Error = error{
    BadArg,
    BufferTooSmall,
    InternalError,
    InvalidPacket,
    Unimplemented,
    InvalidState,
    AllocFail,
    Unknown,
};

fn checkError(code: c_int) Error!void {
    if (code < 0) {
        return switch (code) {
            c.OPUS_BAD_ARG => Error.BadArg,
            c.OPUS_BUFFER_TOO_SMALL => Error.BufferTooSmall,
            c.OPUS_INTERNAL_ERROR => Error.InternalError,
            c.OPUS_INVALID_PACKET => Error.InvalidPacket,
            c.OPUS_UNIMPLEMENTED => Error.Unimplemented,
            c.OPUS_INVALID_STATE => Error.InvalidState,
            c.OPUS_ALLOC_FAIL => Error.AllocFail,
            else => Error.Unknown,
        };
    }
}

fn checkedPositive(code: c_int) Error!usize {
    try checkError(code);
    return @intCast(code);
}

pub const Application = enum(c_int) {
    voip = c.OPUS_APPLICATION_VOIP,
    audio = c.OPUS_APPLICATION_AUDIO,
    restricted_lowdelay = c.OPUS_APPLICATION_RESTRICTED_LOWDELAY,
};

pub const Signal = enum(c_int) {
    auto = c.OPUS_AUTO,
    voice = c.OPUS_SIGNAL_VOICE,
    music = c.OPUS_SIGNAL_MUSIC,
};

pub const Bandwidth = enum(c_int) {
    auto = c.OPUS_AUTO,
    narrowband = c.OPUS_BANDWIDTH_NARROWBAND,
    mediumband = c.OPUS_BANDWIDTH_MEDIUMBAND,
    wideband = c.OPUS_BANDWIDTH_WIDEBAND,
    superwideband = c.OPUS_BANDWIDTH_SUPERWIDEBAND,
    fullband = c.OPUS_BANDWIDTH_FULLBAND,
};

pub const Encoder = struct {
    handle: *c.OpusEncoder,
    mem: []align(16) u8,
    sample_rate: u32,
    channels: u8,

    const Self = @This();

    pub fn getSize(channels: u8) usize {
        return @intCast(c.opus_encoder_get_size(@intCast(channels)));
    }

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, channels: u8, application: Application) (Error || error{OutOfMemory})!Self {
        const size = getSize(channels);
        const mem = try allocator.alignedAlloc(u8, .@"16", size);
        errdefer allocator.free(mem);

        const handle: *c.OpusEncoder = @ptrCast(mem.ptr);
        try checkError(c.opus_encoder_init(handle, @intCast(sample_rate), @intCast(channels), @intFromEnum(application)));

        return .{
            .handle = handle,
            .mem = mem,
            .sample_rate = sample_rate,
            .channels = channels,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.mem);
        self.* = undefined;
    }

    pub fn frameSizeForMs(self: *const Self, ms: u32) u32 {
        return self.sample_rate * ms / 1000;
    }

    pub fn encode(self: *Self, pcm: []const i16, frame_size: u32, out: []u8) Error![]const u8 {
        const n = try checkedPositive(c.opus_encode(
            self.handle,
            pcm.ptr,
            @intCast(frame_size),
            out.ptr,
            @intCast(out.len),
        ));
        return out[0..n];
    }

    pub fn encodeFloat(self: *Self, pcm: []const f32, frame_size: u32, out: []u8) Error![]const u8 {
        const n = try checkedPositive(c.opus_encode_float(
            self.handle,
            pcm.ptr,
            @intCast(frame_size),
            out.ptr,
            @intCast(out.len),
        ));
        return out[0..n];
    }

    pub fn setBitrate(self: *Self, bitrate: u32) Error!void {
        try checkError(c.opus_encoder_ctl(self.handle, c.OPUS_SET_BITRATE_REQUEST, @as(c_int, @intCast(bitrate))));
    }

    pub fn getBitrate(self: *Self) Error!u32 {
        var value: i32 = 0;
        try checkError(c.opus_encoder_ctl(self.handle, c.OPUS_GET_BITRATE_REQUEST, &value));
        return @intCast(value);
    }

    pub fn setComplexity(self: *Self, complexity: u4) Error!void {
        try checkError(c.opus_encoder_ctl(self.handle, c.OPUS_SET_COMPLEXITY_REQUEST, @as(c_int, complexity)));
    }

    pub fn setSignal(self: *Self, signal: Signal) Error!void {
        try checkError(c.opus_encoder_ctl(self.handle, c.OPUS_SET_SIGNAL_REQUEST, @intFromEnum(signal)));
    }

    pub fn setBandwidth(self: *Self, bandwidth: Bandwidth) Error!void {
        try checkError(c.opus_encoder_ctl(self.handle, c.OPUS_SET_BANDWIDTH_REQUEST, @intFromEnum(bandwidth)));
    }

    pub fn setVbr(self: *Self, enable: bool) Error!void {
        try checkError(c.opus_encoder_ctl(self.handle, c.OPUS_SET_VBR_REQUEST, @as(c_int, @intFromBool(enable))));
    }

    pub fn setDtx(self: *Self, enable: bool) Error!void {
        try checkError(c.opus_encoder_ctl(self.handle, c.OPUS_SET_DTX_REQUEST, @as(c_int, @intFromBool(enable))));
    }

    pub fn resetState(self: *Self) Error!void {
        try checkError(c.opus_encoder_ctl(self.handle, c.OPUS_RESET_STATE));
    }
};

pub const Decoder = struct {
    handle: *c.OpusDecoder,
    mem: []align(16) u8,
    sample_rate: u32,
    channels: u8,

    const Self = @This();

    pub fn getSize(channels: u8) usize {
        return @intCast(c.opus_decoder_get_size(@intCast(channels)));
    }

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, channels: u8) (Error || error{OutOfMemory})!Self {
        const size = getSize(channels);
        const mem = try allocator.alignedAlloc(u8, .@"16", size);
        errdefer allocator.free(mem);

        const handle: *c.OpusDecoder = @ptrCast(mem.ptr);
        try checkError(c.opus_decoder_init(handle, @intCast(sample_rate), @intCast(channels)));

        return .{
            .handle = handle,
            .mem = mem,
            .sample_rate = sample_rate,
            .channels = channels,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.mem);
        self.* = undefined;
    }

    pub fn frameSizeForMs(self: *const Self, ms: u32) u32 {
        return self.sample_rate * ms / 1000;
    }

    pub fn decode(self: *Self, data: []const u8, pcm: []i16, fec: bool) Error![]const i16 {
        const frame_size: c_int = @intCast(pcm.len);
        const n = try checkedPositive(c.opus_decode(
            self.handle,
            data.ptr,
            @intCast(data.len),
            pcm.ptr,
            frame_size,
            @intFromBool(fec),
        ));
        return pcm[0..n];
    }

    pub fn decodeFloat(self: *Self, data: []const u8, pcm: []f32, fec: bool) Error![]const f32 {
        const frame_size: c_int = @intCast(pcm.len);
        const n = try checkedPositive(c.opus_decode_float(
            self.handle,
            data.ptr,
            @intCast(data.len),
            pcm.ptr,
            frame_size,
            @intFromBool(fec),
        ));
        return pcm[0..n];
    }

    pub fn plc(self: *Self, pcm: []i16) Error![]const i16 {
        const frame_size: c_int = @intCast(pcm.len);
        const n = try checkedPositive(c.opus_decode(self.handle, null, 0, pcm.ptr, frame_size, 0));
        return pcm[0..n];
    }

    pub fn getSampleRate(self: *Self) Error!u32 {
        var value: i32 = 0;
        try checkError(c.opus_decoder_ctl(self.handle, c.OPUS_GET_SAMPLE_RATE_REQUEST, &value));
        return @intCast(value);
    }

    pub fn resetState(self: *Self) Error!void {
        try checkError(c.opus_decoder_ctl(self.handle, c.OPUS_RESET_STATE));
    }
};

pub fn getVersionString() [*:0]const u8 {
    return c.opus_get_version_string();
}

pub fn packetGetSamples(data: []const u8, sample_rate: u32) Error!u32 {
    return @intCast(try checkedPositive(c.opus_packet_get_nb_samples(data.ptr, @intCast(data.len), @intCast(sample_rate))));
}

pub fn packetGetChannels(data: []const u8) Error!u8 {
    return @intCast(try checkedPositive(c.opus_packet_get_nb_channels(data.ptr)));
}

pub fn packetGetBandwidth(data: []const u8) Error!Bandwidth {
    const ret = c.opus_packet_get_bandwidth(data.ptr);
    try checkError(ret);
    return @enumFromInt(ret);
}

pub fn packetGetFrames(data: []const u8) Error!u32 {
    return @intCast(try checkedPositive(c.opus_packet_get_nb_frames(data.ptr, @intCast(data.len))));
}

test "maps opus negative code to typed error" {
    try std.testing.expectError(Error.BadArg, checkError(c.OPUS_BAD_ARG));
    try std.testing.expectError(Error.InvalidState, checkError(c.OPUS_INVALID_STATE));
}

test "accepts non-negative return codes" {
    try checkError(0);
    try checkError(3);
}
