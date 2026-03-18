const std = @import("std");
const testing = std.testing;
const opus = @import("src.zig");
const Error = opus.Error;
const Application = opus.Application;
const Signal = opus.Signal;
const Bandwidth = opus.Bandwidth;
const Encoder = opus.Encoder;
const Decoder = opus.Decoder;
const getVersionString = opus.getVersionString;
const packetGetSamples = opus.packetGetSamples;
const packetGetChannels = opus.packetGetChannels;
const packetGetBandwidth = opus.packetGetBandwidth;
const packetGetFrames = opus.packetGetFrames;
const checkError = opus.checkError;
const OPUS_BAD_ARG = opus.OPUS_BAD_ARG;
const OPUS_INVALID_STATE = opus.OPUS_INVALID_STATE;

test "maps opus negative code to typed error" {
    try std.testing.expectError(Error.BadArg, checkError(OPUS_BAD_ARG));
    try std.testing.expectError(Error.InvalidState, checkError(OPUS_INVALID_STATE));
}

test "accepts non-negative return codes" {
    try checkError(0);
    try checkError(3);
}
