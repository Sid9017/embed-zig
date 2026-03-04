//! Audio engine — central pipeline for capture, processing, and playback.
//!
//! Data flow:
//!
//!   write(mic_matrix, ref)
//!       │
//!       ▼
//!   [input_queue]  (OverrideBuffer — write overwrites, read blocks)
//!       │  capture task
//!       ▼
//!   Beamformer.process(mic_matrix) → mono
//!       │
//!       ▼
//!   Processor.process(mono, ref, out)
//!       │
//!       ▼
//!   [output_queue]  (OverrideBuffer) → read(buf)
//!
//!   Meanwhile:
//!
//!   Mixer (tracks via createTrack)
//!       │  speaker task
//!       ▼
//!   [speaker_ring]  (OverrideBuffer — circular overwrite, also serves as ref)

const std = @import("std");
const mixer_mod = @import("mixer");
const obuf_mod = @import("override_buffer");
const resampler_mod = @import("resampler");
const runtime = @import("runtime");

const Allocator = std.mem.Allocator;
const Format = resampler_mod.Format;

// ---------------------------------------------------------------------------
// Vtable: Beamformer — multi-mic matrix → mono
// ---------------------------------------------------------------------------

pub const Beamformer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        process: *const fn (ctx: *anyopaque, mic_matrix: []const []const i16, out: []i16) void,
        reset: *const fn (ctx: *anyopaque) void,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn process(self: Beamformer, mic_matrix: []const []const i16, out: []i16) void {
        self.vtable.process(self.ptr, mic_matrix, out);
    }

    pub fn reset(self: Beamformer) void {
        self.vtable.reset(self.ptr);
    }

    pub fn deinit(self: Beamformer) void {
        self.vtable.deinit(self.ptr);
    }
};

// ---------------------------------------------------------------------------
// Vtable: Processor — AEC + NS unified
// ---------------------------------------------------------------------------

pub const Processor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// When `ref` is null the implementation should skip AEC and do NS only.
        process: *const fn (ctx: *anyopaque, mic: []const i16, ref: ?[]const i16, out: []i16) void,
        reset: *const fn (ctx: *anyopaque) void,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn process(self: Processor, mic: []const i16, ref: ?[]const i16, out: []i16) void {
        self.vtable.process(self.ptr, mic, ref, out);
    }

    pub fn reset(self: Processor) void {
        self.vtable.reset(self.ptr);
    }

    pub fn deinit(self: Processor) void {
        self.vtable.deinit(self.ptr);
    }
};

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

pub fn Engine(comptime MutexImpl: type, comptime CondImpl: type, comptime ThreadImpl: type, comptime TimeImpl: type) type {
    comptime _ = runtime.sync.Mutex(MutexImpl);
    comptime _ = runtime.sync.ConditionWithMutex(CondImpl, MutexImpl);
    comptime _ = runtime.thread.from(ThreadImpl);
    comptime _ = runtime.time.from(TimeImpl);

    const MixerType = mixer_mod.Mixer(MutexImpl, CondImpl);
    const InputBuf = obuf_mod.OverrideBuffer(InputFrame, MutexImpl, CondImpl);
    const OutputBuf = obuf_mod.OverrideBuffer(i16, MutexImpl, CondImpl);
    const SpeakerBuf = obuf_mod.OverrideBuffer(i16, MutexImpl, CondImpl);

    return struct {
        const Self = @This();

        pub const Config = struct {
            n_mics: u8 = 1,
            frame_size: u32 = 160,
            sample_rate: u32 = 16000,
            /// Speaker ring capacity in samples.
            speaker_ring_capacity: u32 = 8000,
            /// Input queue capacity in frames.
            input_queue_frames: u32 = 20,
            /// Output queue capacity in samples.
            output_queue_capacity: u32 = 8000,

            /// Real-time duration of one frame in milliseconds.
            pub fn frameIntervalMs(self: Config) u32 {
                return @intCast(@as(u64, self.frame_size) * 1000 / @as(u64, self.sample_rate));
            }
        };

        pub const State = enum(u32) { idle, running, stopping, stopped };

        // -- fields ----------------------------------------------------------

        allocator: Allocator,
        config: Config,
        state: std.atomic.Value(u32),
        mutex: MutexImpl,
        time: TimeImpl,

        beamformer: ?Beamformer,
        processor: ?Processor,

        mixer: MixerType,

        input_queue: InputBuf,
        output_queue: OutputBuf,
        speaker_ring: SpeakerBuf,

        input_storage: []InputFrame,
        output_storage: []i16,
        speaker_storage: []i16,

        capture_thread: ?ThreadImpl,
        speaker_thread: ?ThreadImpl,

        // -- lifecycle -------------------------------------------------------

        pub fn init(allocator: Allocator, config: Config, mutex: MutexImpl, time: TimeImpl) !Self {
            const input_storage = try allocator.alloc(InputFrame, config.input_queue_frames);
            errdefer allocator.free(input_storage);

            const output_storage = try allocator.alloc(i16, config.output_queue_capacity);
            errdefer allocator.free(output_storage);

            const speaker_storage = try allocator.alloc(i16, config.speaker_ring_capacity);
            errdefer allocator.free(speaker_storage);

            return .{
                .allocator = allocator,
                .config = config,
                .state = std.atomic.Value(u32).init(@intFromEnum(State.idle)),
                .mutex = mutex,
                .time = time,
                .beamformer = null,
                .processor = null,
                .mixer = MixerType.init(allocator, .{
                    .output = .{ .rate = config.sample_rate, .channels = .mono },
                }, MutexImpl.init()),
                .input_queue = InputBuf.init(input_storage),
                .output_queue = OutputBuf.init(output_storage),
                .speaker_ring = SpeakerBuf.init(speaker_storage),
                .input_storage = input_storage,
                .output_storage = output_storage,
                .speaker_storage = speaker_storage,
                .capture_thread = null,
                .speaker_thread = null,
            };
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            if (self.beamformer) |bf| bf.deinit();
            if (self.processor) |p| p.deinit();
            self.input_queue.deinit();
            self.output_queue.deinit();
            self.speaker_ring.deinit();
            self.allocator.free(self.input_storage);
            self.allocator.free(self.output_storage);
            self.allocator.free(self.speaker_storage);
            self.mixer.deinit();
            self.mutex.deinit();
        }

        // -- algorithm registration ------------------------------------------

        pub fn setBeamformer(self: *Self, bf: ?Beamformer) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.beamformer) |old| old.deinit();
            self.beamformer = bf;
        }

        pub fn setProcessor(self: *Self, proc: ?Processor) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.processor) |old| old.deinit();
            self.processor = proc;
        }

        // -- control ---------------------------------------------------------

        pub fn start(self: *Self) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const s: State = @enumFromInt(self.state.load(.acquire));
            if (s == .running) return;

            self.state.store(@intFromEnum(State.running), .release);

            self.capture_thread = try ThreadImpl.spawn(
                .{ .name = "engine.capture", .stack_size = 64 * 1024 },
                captureTaskEntry,
                @ptrCast(self),
            );

            self.speaker_thread = try ThreadImpl.spawn(
                .{ .name = "engine.speaker" },
                speakerTaskEntry,
                @ptrCast(self),
            );
        }

        pub fn stop(self: *Self) void {
            const s: State = @enumFromInt(self.state.load(.acquire));
            if (s != .running) return;

            self.state.store(@intFromEnum(State.stopping), .release);

            self.input_queue.close();
            self.output_queue.close();

            if (self.capture_thread) |*t| {
                t.join();
                self.capture_thread = null;
            }
            if (self.speaker_thread) |*t| {
                t.join();
                self.speaker_thread = null;
            }

            self.state.store(@intFromEnum(State.stopped), .release);
        }

        /// Clear all internal audio buffers without stopping the engine.
        /// Useful when switching audio sources (e.g. closing old tracks
        /// and creating new ones) to avoid stale data bleeding through.
        pub fn drainBuffers(self: *Self) void {
            self.input_queue.reset();
            self.output_queue.reset();
            self.speaker_ring.reset();
        }

        // -- capture ingress -------------------------------------------------

        /// Push one aligned frame of multi-mic + optional ref data.
        /// Non-blocking: overwrites oldest frame if queue is full.
        pub fn write(self: *Self, mic_matrix: []const []const i16, ref: ?[]const i16) void {
            self.input_queue.write(&.{InputFrame{
                .mic_matrix = mic_matrix,
                .ref = ref,
            }});
        }

        // -- processed mic output --------------------------------------------

        /// Pull processed (beamformed + NS/AEC) mono audio.
        /// Blocks until `out.len` samples are available.
        /// Returns number of samples read, or 0 if engine stopped.
        pub fn read(self: *Self, out: []i16) usize {
            return self.output_queue.read(out);
        }

        /// Non-blocking read with timeout (nanoseconds).
        pub fn timedRead(self: *Self, out: []i16, timeout_ns: u64) usize {
            return self.output_queue.timedRead(out, timeout_ns);
        }

        // -- mixer passthrough -----------------------------------------------

        pub fn createTrack(self: *Self, config: MixerType.TrackConfig) !MixerType.TrackHandle {
            return self.mixer.createTrack(config);
        }

        // -- speaker output --------------------------------------------------

        /// Pull mixed audio for speaker playback.
        /// Also records into the speaker ring for use as AEC reference.
        pub fn readSpeaker(self: *Self, out: []i16) usize {
            const n = self.mixer.read(out) orelse return 0;
            if (n > 0) self.speaker_ring.write(out[0..n]);
            return n;
        }

        /// Read reference signal from the speaker ring (non-blocking, timed).
        pub fn readRef(self: *Self, out: []i16, timeout_ns: u64) usize {
            return self.speaker_ring.timedRead(out, timeout_ns);
        }

        // -- internal: capture task ------------------------------------------

        fn captureTaskEntry(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.captureLoop();
        }

        fn captureLoop(self: *Self) void {
            while (true) {
                const s: State = @enumFromInt(self.state.load(.acquire));
                if (s != .running) break;

                var frame_buf: [1]InputFrame = undefined;
                const n = self.input_queue.timedRead(&frame_buf, 10 * std.time.ns_per_ms);
                if (n == 0) continue;

                self.processCaptureFrame(frame_buf[0]);
            }
        }

        fn processCaptureFrame(self: *Self, frame: InputFrame) void {
            var beam_buf: [max_frame_samples]i16 = undefined;
            const mono = beam_buf[0..self.config.frame_size];

            if (self.beamformer) |bf| {
                bf.process(frame.mic_matrix, mono);
            } else if (frame.mic_matrix.len > 0 and frame.mic_matrix[0].len >= self.config.frame_size) {
                @memcpy(mono, frame.mic_matrix[0][0..self.config.frame_size]);
            } else {
                @memset(mono, 0);
            }

            var ref_from_ring: [max_frame_samples]i16 = undefined;
            const ref: ?[]const i16 = if (frame.ref) |r|
                r
            else blk: {
                const rn = self.speaker_ring.timedRead(ref_from_ring[0..self.config.frame_size], 0);
                break :blk if (rn == self.config.frame_size) ref_from_ring[0..rn] else null;
            };

            var out_buf: [max_frame_samples]i16 = undefined;
            const out = out_buf[0..self.config.frame_size];

            if (self.processor) |p| {
                p.process(mono, ref, out);
            } else {
                @memcpy(out, mono);
            }

            self.output_queue.write(out);
        }

        // -- internal: speaker task ------------------------------------------

        fn speakerTaskEntry(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.speakerLoop();
        }

        fn speakerLoop(self: *Self) void {
            var spk_buf: [max_frame_samples]i16 = undefined;
            const frame = spk_buf[0..self.config.frame_size];
            const interval_ms = self.config.frameIntervalMs();
            var next_deadline: u64 = self.time.nowMs() + interval_ms;

            while (true) {
                const s: State = @enumFromInt(self.state.load(.acquire));
                if (s != .running) break;

                const n = self.mixer.read(frame) orelse 0;
                if (n > 0) {
                    self.speaker_ring.write(frame[0..n]);
                }

                const now = self.time.nowMs();
                if (now < next_deadline) {
                    self.time.sleepMs(@intCast(next_deadline - now));
                }
                next_deadline += interval_ms;
            }
        }

        const max_frame_samples = 4096;
    };
}

/// Frame pushed into the input queue via `write`.
pub const InputFrame = struct {
    mic_matrix: []const []const i16,
    ref: ?[]const i16,
};

// ---------------------------------------------------------------------------
// Passthrough implementations (testing / bring-up)
// ---------------------------------------------------------------------------

pub const PassthroughBeamformer = struct {
    pub fn beamformer(self: *PassthroughBeamformer) Beamformer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = Beamformer.VTable{
        .process = &processTakeFirst,
        .reset = &noop,
        .deinit = &noop,
    };

    fn processTakeFirst(_: *anyopaque, mic_matrix: []const []const i16, out: []i16) void {
        if (mic_matrix.len > 0) {
            const src = mic_matrix[0];
            @memcpy(out[0..src.len], src);
        } else {
            @memset(out, 0);
        }
    }

    fn noop(_: *anyopaque) void {}
};

pub const PassthroughProcessor = struct {
    pub fn processor(self: *PassthroughProcessor) Processor {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = Processor.VTable{
        .process = &processCopy,
        .reset = &noop,
        .deinit = &noop,
    };

    fn processCopy(_: *anyopaque, mic: []const i16, _: ?[]const i16, out: []i16) void {
        @memcpy(out[0..mic.len], mic);
    }

    fn noop(_: *anyopaque) void {}
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const TestEngine = Engine(runtime.std.Mutex, runtime.std.Condition, runtime.std.Thread, runtime.std.Time);

fn newEngine(config: TestEngine.Config) !TestEngine {
    return TestEngine.init(testing.allocator, config, runtime.std.Mutex.init(), runtime.std.Time{});
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

    var bf = PassthroughBeamformer{};
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

    var proc = PassthroughProcessor{};
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

    const fmt = Format{ .rate = 16000, .channels = .mono };
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
