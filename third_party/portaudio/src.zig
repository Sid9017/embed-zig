//! Zig bindings for PortAudio.
//!
//! PortAudio is a cross-platform audio I/O library that offers a unified
//! callback/blocking API for input and output streams.

const std = @import("std");
pub const c = @cImport({
    @cInclude("portaudio.h");
});

pub const Stream = c.PaStream;
pub const DeviceIndex = c.PaDeviceIndex;
pub const HostApiIndex = c.PaHostApiIndex;
pub const Time = c.PaTime;
pub const SampleFormat = c.PaSampleFormat;
pub const StreamFlags = c.PaStreamFlags;
pub const StreamCallbackFlags = c.PaStreamCallbackFlags;
pub const StreamParameters = c.PaStreamParameters;
pub const StreamInfo = c.PaStreamInfo;
pub const DeviceInfo = c.PaDeviceInfo;
pub const HostApiInfo = c.PaHostApiInfo;
pub const HostErrorInfo = c.PaHostErrorInfo;

pub const Error = error{
    NotInitialized,
    UnanticipatedHostError,
    InvalidChannelCount,
    InvalidSampleRate,
    InvalidDevice,
    InvalidFlag,
    SampleFormatNotSupported,
    BadIODeviceCombination,
    InsufficientMemory,
    BufferTooBig,
    BufferTooSmall,
    NullCallback,
    BadStreamPtr,
    TimedOut,
    InternalError,
    DeviceUnavailable,
    IncompatibleHostApiSpecificStreamInfo,
    StreamIsStopped,
    StreamIsNotStopped,
    InputOverflowed,
    OutputUnderflowed,
    HostApiNotFound,
    InvalidHostApi,
    CanNotReadFromACallbackStream,
    CanNotWriteToACallbackStream,
    CanNotReadFromAnOutputOnlyStream,
    CanNotWriteToAnInputOnlyStream,
    IncompatibleStreamHostApi,
    BadBufferPtr,
    Unknown,
};

pub fn check(code: c.PaError) Error!void {
    if (code >= c.paNoError) return;
    return switch (code) {
        c.paNotInitialized => Error.NotInitialized,
        c.paUnanticipatedHostError => Error.UnanticipatedHostError,
        c.paInvalidChannelCount => Error.InvalidChannelCount,
        c.paInvalidSampleRate => Error.InvalidSampleRate,
        c.paInvalidDevice => Error.InvalidDevice,
        c.paInvalidFlag => Error.InvalidFlag,
        c.paSampleFormatNotSupported => Error.SampleFormatNotSupported,
        c.paBadIODeviceCombination => Error.BadIODeviceCombination,
        c.paInsufficientMemory => Error.InsufficientMemory,
        c.paBufferTooBig => Error.BufferTooBig,
        c.paBufferTooSmall => Error.BufferTooSmall,
        c.paNullCallback => Error.NullCallback,
        c.paBadStreamPtr => Error.BadStreamPtr,
        c.paTimedOut => Error.TimedOut,
        c.paInternalError => Error.InternalError,
        c.paDeviceUnavailable => Error.DeviceUnavailable,
        c.paIncompatibleHostApiSpecificStreamInfo => Error.IncompatibleHostApiSpecificStreamInfo,
        c.paStreamIsStopped => Error.StreamIsStopped,
        c.paStreamIsNotStopped => Error.StreamIsNotStopped,
        c.paInputOverflowed => Error.InputOverflowed,
        c.paOutputUnderflowed => Error.OutputUnderflowed,
        c.paHostApiNotFound => Error.HostApiNotFound,
        c.paInvalidHostApi => Error.InvalidHostApi,
        c.paCanNotReadFromACallbackStream => Error.CanNotReadFromACallbackStream,
        c.paCanNotWriteToACallbackStream => Error.CanNotWriteToACallbackStream,
        c.paCanNotReadFromAnOutputOnlyStream => Error.CanNotReadFromAnOutputOnlyStream,
        c.paCanNotWriteToAnInputOnlyStream => Error.CanNotWriteToAnInputOnlyStream,
        c.paIncompatibleStreamHostApi => Error.IncompatibleStreamHostApi,
        c.paBadBufferPtr => Error.BadBufferPtr,
        else => Error.Unknown,
    };
}

pub fn getVersion() c_int {
    return c.Pa_GetVersion();
}

pub fn getVersionText() [*:0]const u8 {
    return c.Pa_GetVersionText();
}

pub fn initialize() Error!void {
    try check(c.Pa_Initialize());
}

pub fn terminate() Error!void {
    try check(c.Pa_Terminate());
}

fn checkNonNegative(code: c_long) Error!c_long {
    if (code >= 0) return code;
    try check(@as(c.PaError, @intCast(code)));
    unreachable;
}

pub fn getDeviceCount() Error!u32 {
    const count = c.Pa_GetDeviceCount();
    try check(count);
    return @intCast(count);
}

pub fn getDefaultInputDevice() ?DeviceIndex {
    const device = c.Pa_GetDefaultInputDevice();
    if (device == c.paNoDevice) return null;
    return device;
}

pub fn getDefaultOutputDevice() ?DeviceIndex {
    const device = c.Pa_GetDefaultOutputDevice();
    if (device == c.paNoDevice) return null;
    return device;
}

pub fn getErrorText(code: c.PaError) [*:0]const u8 {
    return c.Pa_GetErrorText(code);
}

pub const AudioIO = struct {
    pub const OutputConfig = struct {
        channels: u8 = 2,
        sample_rate: f64 = 48_000,
        frames_per_buffer: u32 = 256,
    };

    pub const InputConfig = struct {
        channels: u8 = 1,
        sample_rate: f64 = 16_000,
        frames_per_buffer: u32 = 160,
    };

    stream: ?*Stream = null,
    channels: u8 = 0,
    in_channels: u8 = 0,
    initialized: bool = false,

    pub fn init() Error!AudioIO {
        try initialize();
        return .{ .initialized = true };
    }

    pub fn deinit(self: *AudioIO) void {
        self.closeStream() catch {};
        if (self.initialized) {
            terminate() catch {};
            self.initialized = false;
        }
    }

    pub fn openDefaultOutput(self: *AudioIO, cfg: OutputConfig) Error!void {
        if (cfg.channels == 0) return Error.InvalidChannelCount;
        if (self.stream != null) try self.closeStream();

        var stream: ?*Stream = null;
        try check(c.Pa_OpenDefaultStream(
            @ptrCast(&stream),
            0,
            @as(c_int, cfg.channels),
            c.paInt16,
            cfg.sample_rate,
            @as(c_ulong, cfg.frames_per_buffer),
            null,
            null,
        ));

        self.stream = stream orelse return Error.Unknown;
        self.channels = cfg.channels;
    }

    pub fn openDefaultInput(self: *AudioIO, cfg: InputConfig) Error!void {
        if (cfg.channels == 0) return Error.InvalidChannelCount;
        if (self.stream != null) try self.closeStream();

        var stream: ?*Stream = null;
        try check(c.Pa_OpenDefaultStream(
            @ptrCast(&stream),
            @as(c_int, cfg.channels),
            0,
            c.paInt16,
            cfg.sample_rate,
            @as(c_ulong, cfg.frames_per_buffer),
            null,
            null,
        ));

        self.stream = stream orelse return Error.Unknown;
        self.in_channels = cfg.channels;
    }

    pub fn openDefaultDuplex(self: *AudioIO, in_cfg: InputConfig, out_cfg: OutputConfig) Error!void {
        if (in_cfg.channels == 0 or out_cfg.channels == 0) return Error.InvalidChannelCount;
        if (in_cfg.sample_rate != out_cfg.sample_rate) return Error.InvalidSampleRate;
        if (self.stream != null) try self.closeStream();

        var stream: ?*Stream = null;
        try check(c.Pa_OpenDefaultStream(
            @ptrCast(&stream),
            @as(c_int, in_cfg.channels),
            @as(c_int, out_cfg.channels),
            c.paInt16,
            out_cfg.sample_rate,
            @as(c_ulong, out_cfg.frames_per_buffer),
            null,
            null,
        ));

        self.stream = stream orelse return Error.Unknown;
        self.channels = out_cfg.channels;
        self.in_channels = in_cfg.channels;
    }

    pub fn start(self: *AudioIO) Error!void {
        const stream = self.stream orelse return Error.BadStreamPtr;
        try check(c.Pa_StartStream(stream));
    }

    pub fn stop(self: *AudioIO) Error!void {
        const stream = self.stream orelse return;
        try check(c.Pa_StopStream(stream));
    }

    pub fn closeStream(self: *AudioIO) Error!void {
        const stream = self.stream orelse return;
        self.stream = null;
        self.channels = 0;
        self.in_channels = 0;
        try check(c.Pa_CloseStream(stream));
    }

    pub fn writeI16(self: *AudioIO, samples: []const i16) Error!void {
        const stream = self.stream orelse return Error.BadStreamPtr;
        if (self.channels == 0) return Error.InvalidChannelCount;
        if (samples.len % self.channels != 0) return Error.BadBufferPtr;
        const frames = samples.len / self.channels;
        try check(c.Pa_WriteStream(stream, samples.ptr, @as(c_ulong, @intCast(frames))));
    }

    pub fn readI16(self: *AudioIO, out: []i16) Error!void {
        const stream = self.stream orelse return Error.BadStreamPtr;
        const ch: u32 = if (self.in_channels > 0) self.in_channels else 1;
        if (out.len % ch != 0) return Error.BadBufferPtr;
        const frames = out.len / ch;
        try check(c.Pa_ReadStream(stream, out.ptr, @as(c_ulong, @intCast(frames))));
    }

    pub fn readAvailableFrames(self: *AudioIO) Error!u32 {
        const stream = self.stream orelse return Error.BadStreamPtr;
        const n = try checkNonNegative(c.Pa_GetStreamReadAvailable(stream));
        return @intCast(n);
    }

    pub fn writeAvailableFrames(self: *AudioIO) Error!u32 {
        const stream = self.stream orelse return Error.BadStreamPtr;
        const n = try checkNonNegative(c.Pa_GetStreamWriteAvailable(stream));
        return @intCast(n);
    }

    pub const LatencyInfo = struct {
        input_latency_ms: f64,
        output_latency_ms: f64,
        sample_rate: f64,
    };

    pub fn getLatencyInfo(self: *AudioIO) Error!LatencyInfo {
        const stream = self.stream orelse return Error.BadStreamPtr;
        const info: *const StreamInfo = c.Pa_GetStreamInfo(stream) orelse return Error.BadStreamPtr;
        return .{
            .input_latency_ms = info.inputLatency * 1000.0,
            .output_latency_ms = info.outputLatency * 1000.0,
            .sample_rate = info.sampleRate,
        };
    }

    /// Poll-like helper, inspired by runtime.io's `poll` style:
    /// returns true when stream has write capacity within timeout.
    pub fn pollWritable(self: *AudioIO, timeout_ms: i32) Error!bool {
        const sleep_ns = 2 * std.time.ns_per_ms;
        if (timeout_ms == 0) {
            return (try self.writeAvailableFrames()) > 0;
        }
        if (timeout_ms < 0) {
            while (true) {
                if ((try self.writeAvailableFrames()) > 0) return true;
                std.Thread.sleep(sleep_ns);
            }
        }

        const start_ms = std.time.milliTimestamp();
        while (true) {
            if ((try self.writeAvailableFrames()) > 0) return true;
            const elapsed = std.time.milliTimestamp() - start_ms;
            if (elapsed >= timeout_ms) return false;
            std.Thread.sleep(sleep_ns);
        }
    }
};

test "version metadata is available" {
    try std.testing.expect(getVersion() > 0);
    const text = std.mem.span(getVersionText());
    try std.testing.expect(text.len > 0);
}

test "known error maps to typed Zig error" {
    try std.testing.expectError(Error.InvalidDevice, check(c.paInvalidDevice));
}

test "error text is non-empty for known code" {
    const text = std.mem.span(getErrorText(c.paInvalidSampleRate));
    try std.testing.expect(text.len > 0);
}
