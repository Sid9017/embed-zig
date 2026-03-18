const std = @import("std");
const embed = @import("embed");
const engine = embed.pkg.audio.engine;
const resampler = embed.pkg.audio.resampler;

const StdRuntime = embed.runtime.std;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const TestEngine = engine.Engine(StdRuntime);

fn newEngine(config: TestEngine.Config) !TestEngine {
    return TestEngine.init(testing.allocator, config, StdRuntime.Mutex.init(), StdRuntime.Time{});
}

const test_frame_size: u32 = 8;

fn testConfig() TestEngine.Config {
    return .{
        .n_mics = 1,
        .frame_size = test_frame_size,
        .sample_rate = 16000,
        .input_queue_frames = 4,
        .output_queue_capacity = 256,
        .speaker_ring_capacity = 256,
    };
}

test "engine init and deinit" {
    var eng = try newEngine(testConfig());
    defer eng.deinit();

    const s: TestEngine.State = @enumFromInt(eng.state.load(.acquire));
    try testing.expectEqual(TestEngine.State.idle, s);
}

test "engine start and stop" {
    var eng = try newEngine(testConfig());
    defer eng.deinit();

    try eng.start();
    const s1: TestEngine.State = @enumFromInt(eng.state.load(.acquire));
    try testing.expectEqual(TestEngine.State.running, s1);

    eng.stop();
    const s2: TestEngine.State = @enumFromInt(eng.state.load(.acquire));
    try testing.expectEqual(TestEngine.State.stopped, s2);
}

test "engine passthrough: write mono mic, read processed output" {
    var eng = try newEngine(testConfig());
    defer eng.deinit();

    try eng.start();

    const mic_data = [_]i16{ 100, 200, 300, 400, 500, 600, 700, 800 };
    const mic_slice: []const i16 = &mic_data;
    const matrix = [_][]const i16{mic_slice};

    eng.write(&matrix, null);

    var out: [test_frame_size]i16 = undefined;
    const n = eng.timedRead(&out, 500 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, test_frame_size), n);
    try testing.expectEqualSlices(i16, &mic_data, &out);

    eng.stop();
}

test "engine passthrough: multiple frames flow through" {
    var eng = try newEngine(testConfig());
    defer eng.deinit();

    try eng.start();

    const frame1 = [_]i16{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const frame2 = [_]i16{ 10, 20, 30, 40, 50, 60, 70, 80 };
    const s1: []const i16 = &frame1;
    const s2: []const i16 = &frame2;
    const m1 = [_][]const i16{s1};
    const m2 = [_][]const i16{s2};

    eng.write(&m1, null);
    eng.write(&m2, null);

    var out1: [test_frame_size]i16 = undefined;
    var out2: [test_frame_size]i16 = undefined;

    const n1 = eng.timedRead(&out1, 500 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, test_frame_size), n1);
    try testing.expectEqualSlices(i16, &frame1, &out1);

    const n2 = eng.timedRead(&out2, 500 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, test_frame_size), n2);
    try testing.expectEqualSlices(i16, &frame2, &out2);

    eng.stop();
}

test "engine with passthrough beamformer takes first mic" {
    var eng = try newEngine(testConfig());
    defer eng.deinit();

    var bf = engine.PassthroughBeamformer{};
    eng.setBeamformer(bf.beamformer());

    try eng.start();

    const mic0 = [_]i16{ 11, 22, 33, 44, 55, 66, 77, 88 };
    const mic1 = [_]i16{ 99, 99, 99, 99, 99, 99, 99, 99 };
    const s0: []const i16 = &mic0;
    const s1: []const i16 = &mic1;
    const matrix = [_][]const i16{ s0, s1 };

    eng.write(&matrix, null);

    var out: [test_frame_size]i16 = undefined;
    const n = eng.timedRead(&out, 500 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, test_frame_size), n);
    try testing.expectEqualSlices(i16, &mic0, &out);

    eng.stop();
}

test "engine with passthrough processor copies mic to output" {
    var eng = try newEngine(testConfig());
    defer eng.deinit();

    var proc = engine.PassthroughProcessor{};
    eng.setProcessor(proc.processor());

    try eng.start();

    const mic_data = [_]i16{ -100, -200, -300, -400, -500, -600, -700, -800 };
    const mic_slice: []const i16 = &mic_data;
    const matrix = [_][]const i16{mic_slice};

    eng.write(&matrix, null);

    var out: [test_frame_size]i16 = undefined;
    const n = eng.timedRead(&out, 500 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, test_frame_size), n);
    try testing.expectEqualSlices(i16, &mic_data, &out);

    eng.stop();
}

test "engine timedRead returns 0 when no data and timeout expires" {
    var eng = try newEngine(testConfig());
    defer eng.deinit();

    try eng.start();

    var out: [test_frame_size]i16 = undefined;
    const n = eng.timedRead(&out, 5 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, 0), n);

    eng.stop();
}

test "engine speaker ring receives mixer output" {
    var eng = try newEngine(testConfig());
    defer eng.deinit();

    const fmt = resampler.Format{ .rate = 16000, .channels = .mono };
    const h = try eng.createTrack(.{});
    const samples = [_]i16{ 500, 600, 700, 800, 500, 600, 700, 800 };
    try h.track.write(fmt, &samples);
    h.ctrl.closeWrite();

    var spk_out: [8]i16 = undefined;
    const n = eng.readSpeaker(&spk_out);
    try testing.expect(n > 0);

    var ref_out: [8]i16 = undefined;
    const rn = eng.readRef(&ref_out, 5 * std.time.ns_per_ms);
    try testing.expect(rn > 0);
}

test "engine stop unblocks blocked reader" {
    var eng = try newEngine(testConfig());
    defer eng.deinit();

    try eng.start();

    var read_result = std.atomic.Value(usize).init(999);

    const reader = try std.Thread.spawn(.{}, struct {
        fn run(e: *TestEngine, res: *std.atomic.Value(usize)) void {
            var out: [test_frame_size]i16 = undefined;
            const n = e.timedRead(&out, 200 * std.time.ns_per_ms);
            res.store(n, .release);
        }
    }.run, .{ &eng, &read_result });

    std.Thread.sleep(20 * std.time.ns_per_ms);
    eng.stop();
    reader.join();

    try testing.expectEqual(@as(usize, 0), read_result.load(.acquire));
}

test "engine concurrent write and read" {
    var eng = try newEngine(testConfig());
    defer eng.deinit();

    try eng.start();

    const writer = try std.Thread.spawn(.{}, struct {
        fn run(e: *TestEngine) void {
            var i: i16 = 0;
            while (i < 10) : (i += 1) {
                var frame: [test_frame_size]i16 = undefined;
                for (&frame) |*s| {
                    s.* = i * 10;
                }
                const slice: []const i16 = &frame;
                const matrix = [_][]const i16{slice};
                e.write(&matrix, null);
                std.Thread.sleep(2 * std.time.ns_per_ms);
            }
        }
    }.run, .{&eng});

    var total_read: usize = 0;
    var buf: [test_frame_size]i16 = undefined;
    while (total_read < test_frame_size * 5) {
        const n = eng.timedRead(&buf, 100 * std.time.ns_per_ms);
        if (n == 0) break;
        total_read += n;
    }

    writer.join();
    eng.stop();

    try testing.expect(total_read >= test_frame_size);
}
