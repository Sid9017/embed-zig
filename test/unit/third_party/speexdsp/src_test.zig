const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const speexdsp = embed.third_party.speexdsp;

// ── tests ─────────────────────────────────────────────────────────────────

test "echo canceller lifecycle" {
    var aec = speexdsp.EchoCanceller.init(160, 1024) orelse return error.InitFailed;
    defer aec.deinit();

    aec.setSamplingRate(16000);
    try std.testing.expectEqual(@as(i32, 16000), aec.getSamplingRate());

    aec.reset();
}

test "echo canceller cancel zero frame" {
    var aec = speexdsp.EchoCanceller.init(160, 1024) orelse return error.InitFailed;
    defer aec.deinit();
    aec.setSamplingRate(16000);

    var rec = [_]i16{0} ** 160;
    var play = [_]i16{0} ** 160;
    var out = [_]i16{0} ** 160;

    aec.cancel(&rec, &play, &out);
}

test "preprocessor lifecycle" {
    var pp = speexdsp.Preprocessor.init(160, 16000) orelse return error.InitFailed;
    defer pp.deinit();

    pp.setDenoise(true);
    pp.setNoiseSuppress(-20);
    pp.setAgc(true);
    pp.setAgcLevel(8000);
    pp.setVad(true);
    pp.setDereverb(false);
}

test "preprocessor run zero frame" {
    var pp = speexdsp.Preprocessor.init(160, 16000) orelse return error.InitFailed;
    defer pp.deinit();

    var audio = [_]i16{0} ** 160;
    _ = pp.run(&audio);
}

test "preprocessor linked to echo canceller" {
    var aec = speexdsp.EchoCanceller.init(160, 1024) orelse return error.InitFailed;
    defer aec.deinit();
    aec.setSamplingRate(16000);

    var pp = speexdsp.Preprocessor.init(160, 16000) orelse return error.InitFailed;
    defer pp.deinit();
    pp.setEchoState(&aec);

    var audio = [_]i16{0} ** 160;
    _ = pp.run(&audio);

    pp.clearEchoState();
}

test "resampler lifecycle" {
    var rs = try speexdsp.Resampler.init(1, 48000, 16000, 5);
    defer rs.deinit();

    const rate = rs.getRate();
    try std.testing.expectEqual(@as(u32, 48000), rate.in_rate);
    try std.testing.expectEqual(@as(u32, 16000), rate.out_rate);

    try std.testing.expectEqual(@as(c_int, 5), rs.getQuality());
    try std.testing.expect(rs.getInputLatency() >= 0);
    try std.testing.expect(rs.getOutputLatency() >= 0);
}

test "resampler 48k to 16k" {
    var rs = try speexdsp.Resampler.init(1, 48000, 16000, 5);
    defer rs.deinit();

    var input = [_]i16{0} ** 480;
    var output = [_]i16{0} ** 200;
    const result = try rs.processInt(0, &input, &output);

    try std.testing.expectEqual(@as(u32, 480), result.in_consumed);
    try std.testing.expect(result.out_written > 0);
}

test "jitter buffer lifecycle" {
    var jb = speexdsp.JitterBuffer.init(160) orelse return error.InitFailed;
    defer jb.deinit();

    jb.tick();
    jb.reset();
}

test "buffer write and read" {
    var buf = speexdsp.Buffer.init(256) orelse return error.InitFailed;
    defer buf.deinit();

    try std.testing.expectEqual(@as(c_int, 0), buf.getAvailable());

    const data = "hello speexdsp";
    _ = buf.write(data);
    try std.testing.expectEqual(@as(c_int, @intCast(data.len)), buf.getAvailable());

    var out: [32]u8 = undefined;
    const n = buf.read(out[0..data.len]);
    try std.testing.expectEqual(@as(c_int, @intCast(data.len)), n);
    try std.testing.expectEqualSlices(u8, data, out[0..@intCast(n)]);
}

test "buffer write zeros" {
    var buf = speexdsp.Buffer.init(256) orelse return error.InitFailed;
    defer buf.deinit();

    _ = buf.writeZeros(16);
    try std.testing.expectEqual(@as(c_int, 16), buf.getAvailable());
}
