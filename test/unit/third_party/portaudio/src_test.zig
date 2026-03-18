const std = @import("std");
const testing = std.testing;
const portaudio = @import("src.zig");
const c = portaudio.c;
const Stream = portaudio.Stream;
const DeviceIndex = portaudio.DeviceIndex;
const HostApiIndex = portaudio.HostApiIndex;
const Time = portaudio.Time;
const SampleFormat = portaudio.SampleFormat;
const StreamFlags = portaudio.StreamFlags;
const StreamCallbackFlags = portaudio.StreamCallbackFlags;
const StreamParameters = portaudio.StreamParameters;
const StreamInfo = portaudio.StreamInfo;
const DeviceInfo = portaudio.DeviceInfo;
const HostApiInfo = portaudio.HostApiInfo;
const HostErrorInfo = portaudio.HostErrorInfo;
const Error = portaudio.Error;
const check = portaudio.check;
const getVersion = portaudio.getVersion;
const getVersionText = portaudio.getVersionText;
const initialize = portaudio.initialize;
const terminate = portaudio.terminate;
const getDeviceCount = portaudio.getDeviceCount;
const getDefaultInputDevice = portaudio.getDefaultInputDevice;
const getDefaultOutputDevice = portaudio.getDefaultOutputDevice;
const getErrorText = portaudio.getErrorText;
const AudioIO = portaudio.AudioIO;

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
