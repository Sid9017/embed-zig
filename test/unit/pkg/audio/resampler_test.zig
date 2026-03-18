const std = @import("std");
const embed = @import("embed");
const resampler = embed.pkg.audio.resampler;

test "format helpers and conversions" {
    const testing = std.testing;
    const mono = resampler.Format{ .rate = 16000, .channels = .mono };
    const stereo = resampler.Format{ .rate = 48000, .channels = .stereo };
    try testing.expectEqual(@as(usize, 2), mono.sampleBytes());
    try testing.expectEqual(@as(usize, 4), stereo.sampleBytes());

    var interleaved = [_]i16{ 100, 300, 200, 400 };
    const mono_n = resampler.stereoToMono(&interleaved);
    try testing.expectEqual(@as(usize, 2), mono_n);
    try testing.expectEqual(@as(i16, 200), interleaved[0]);
    try testing.expectEqual(@as(i16, 300), interleaved[1]);

    const mono_samples = [_]i16{ 5, 10 };
    var stereo_out: [4]i16 = undefined;
    _ = resampler.monoToStereo(&mono_samples, &stereo_out);
    try testing.expectEqualSlices(i16, &[_]i16{ 5, 5, 10, 10 }, &stereo_out);
}

test "resampler same rate copy" {
    const testing = std.testing;
    var rs = try resampler.Resampler.init(testing.allocator, .{
        .channels = 1,
        .in_rate = 16000,
        .out_rate = 16000,
    });
    defer rs.deinit();

    const input = [_]i16{ 1, 2, 3, 4 };
    var out: [4]i16 = undefined;
    const r = try rs.process(&input, &out);
    try testing.expectEqual(@as(u32, 4), r.in_consumed);
    try testing.expectEqual(@as(u32, 4), r.out_produced);
    try testing.expectEqualSlices(i16, &input, &out);
}
