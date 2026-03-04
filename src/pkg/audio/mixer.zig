//! Multi-track PCM mixer.
//!
//! Compared with legacy `embed-zig/lib/pkg/audio/src/mixer.zig`, this migration
//! baseline keeps the core external behavior:
//! - track create/write/read/close flow
//! - gain + label + readBytes accounting
//! - per-track format conversion through resampler helpers
//! while using a simpler in-memory queue strategy for deterministic bring-up.

const std = @import("std");
const resampler_mod = @import("resampler");
const runtime = @import("runtime");

const Allocator = std.mem.Allocator;
const Resampler = resampler_mod.Resampler;

/// Bounded sample buffer for mixer tracks.
/// Write blocks when the buffer is at capacity (backpressure).
/// Read is non-blocking — returns however many samples are available.
pub fn Buffer(comptime MutexImpl: type, comptime CondImpl: type) type {
    comptime _ = runtime.sync.Mutex(MutexImpl);
    comptime _ = runtime.sync.ConditionWithMutex(CondImpl, MutexImpl);

    return struct {
        const Self = @This();

        allocator: Allocator,
        items: []i16,
        len: usize,
        capacity: usize,
        closed: bool,
        mutex: MutexImpl,
        not_full: CondImpl,

        pub fn init(allocator: Allocator, capacity: usize) Allocator.Error!Self {
            const items = try allocator.alloc(i16, capacity);
            return .{
                .allocator = allocator,
                .items = items,
                .len = 0,
                .capacity = capacity,
                .closed = false,
                .mutex = MutexImpl.init(),
                .not_full = CondImpl.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.not_full.deinit();
            self.mutex.deinit();
            self.allocator.free(self.items);
            self.* = undefined;
        }

        /// Blocking write — appends samples, waiting when buffer is full.
        pub fn write(self: *Self, samples: []const i16) error{Closed}!void {
            var offset: usize = 0;
            self.mutex.lock();
            defer self.mutex.unlock();

            while (offset < samples.len) {
                if (self.closed) return error.Closed;

                while (self.len >= self.capacity and !self.closed) {
                    self.not_full.wait(&self.mutex);
                }
                if (self.closed) return error.Closed;

                const space = self.capacity - self.len;
                const n = @min(samples.len - offset, space);
                @memcpy(self.items[self.len .. self.len + n], samples[offset .. offset + n]);
                self.len += n;
                offset += n;
            }
        }

        /// Non-blocking write — appends as many samples as space allows.
        pub fn tryWrite(self: *Self, samples: []const i16) error{Closed}!usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) return error.Closed;

            const space = self.capacity - self.len;
            const n = @min(samples.len, space);
            if (n == 0) return 0;
            @memcpy(self.items[self.len .. self.len + n], samples[0..n]);
            self.len += n;
            return n;
        }

        /// Non-blocking read — consumes up to `out.len` samples.
        pub fn read(self: *Self, out: []i16) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.readLocked(out);
        }

        /// Readable slice of buffered data (caller must hold lock).
        pub fn readableSlice(self: *Self) []const i16 {
            return self.items[0..self.len];
        }

        /// Consume `n` samples from the front (caller must hold lock).
        pub fn consumeLocked(self: *Self, n: usize) void {
            const actual = @min(n, self.len);
            if (actual == 0) return;
            const remaining = self.len - actual;
            if (remaining > 0) {
                std.mem.copyForwards(i16, self.items[0..remaining], self.items[actual..self.len]);
            }
            self.len = remaining;
            self.not_full.signal();
        }

        pub fn lock(self: *Self) void {
            self.mutex.lock();
        }

        pub fn unlock(self: *Self) void {
            self.mutex.unlock();
        }

        pub fn count(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.len;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.not_full.broadcast();
        }

        pub fn isClosed(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.closed;
        }

        fn readLocked(self: *Self, out: []i16) usize {
            const n = @min(out.len, self.len);
            if (n == 0) return 0;
            @memcpy(out[0..n], self.items[0..n]);
            self.consumeLocked(n);
            return n;
        }
    };
}

pub fn Mixer(comptime MutexImpl: type, comptime CondImpl: type) type {
    comptime _ = runtime.sync.Mutex(MutexImpl);
    comptime _ = runtime.sync.ConditionWithMutex(CondImpl, MutexImpl);

    const BufferType = Buffer(MutexImpl, CondImpl);

    return struct {
        const Self = @This();
        pub const Format = resampler_mod.Format;

        pub const Config = struct {
            output: Format,
            auto_close: bool = false,
            silence_gap_ms: u32 = 0,
            on_track_created: ?*const fn () void = null,
            on_track_closed: ?*const fn () void = null,
        };

        pub const TrackConfig = struct {
            label: []const u8 = "",
            gain: f32 = 1.0,
            buffer_capacity: usize = 32000,
        };

        pub const TrackHandle = struct {
            track: *Track,
            ctrl: *TrackCtrl,
        };

        allocator: Allocator,
        config: Config,
        mutex: MutexImpl,
        close_write: bool = false,
        close_err: bool = false,
        tracks: std.ArrayList(*TrackCtrl),

        pub fn init(allocator: Allocator, config: Config, mutex: MutexImpl) Self {
            return .{
                .allocator = allocator,
                .config = config,
                .mutex = mutex,
                .tracks = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.tracks.items) |ctrl| {
                ctrl.deinit(self.allocator);
                self.allocator.destroy(ctrl);
            }
            self.tracks.deinit(self.allocator);
            self.mutex.deinit();
        }

        pub fn createTrack(self: *Self, config: TrackConfig) error{ Closed, OutOfMemory }!TrackHandle {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.close_write or self.close_err) return error.Closed;

            const ctrl = try self.allocator.create(TrackCtrl);
            try ctrl.init(self.allocator, self, config);
            try self.tracks.append(self.allocator, ctrl);
            if (self.config.on_track_created) |cb| cb();
            return .{ .track = &ctrl.track_handle, .ctrl = ctrl };
        }

        pub fn destroyTrackCtrl(self: *Self, ctrl: *TrackCtrl) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var i: usize = 0;
            while (i < self.tracks.items.len) : (i += 1) {
                if (self.tracks.items[i] == ctrl) {
                    _ = self.tracks.swapRemove(i);
                    break;
                }
            }
            ctrl.deinit(self.allocator);
            self.allocator.destroy(ctrl);
        }

        pub fn closeWrite(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.close_write = true;
            for (self.tracks.items) |t| {
                t.closed = true;
                t.buffer.close();
            }
        }

        pub fn close(self: *Self) void {
            self.closeWithError();
        }

        pub fn closeWithError(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.close_err = true;
            self.close_write = true;
            for (self.tracks.items) |t| {
                t.closed = true;
                t.errored = true;
                t.buffer.close();
            }
        }

        /// Read mixed audio into `buf`.
        /// Returns:
        /// - `null` when mixer is drained and closed
        /// - `0` when no data available yet
        /// - `n > 0` mixed samples
        pub fn read(self: *Self, buf: []i16) ?usize {
            if (buf.len == 0) return 0;

            self.mutex.lock();
            defer self.mutex.unlock();

            @memset(buf, 0);
            var has_data = false;
            var active_tracks: usize = 0;

            // Phase 1: destroy tracks that were marked drained on a previous read().
            // This gives callers one read() cycle to inspect final state (readBytes, etc.)
            // before the TrackCtrl pointer becomes invalid.
            var to_remove = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return null;
            defer to_remove.deinit(self.allocator);

            for (self.tracks.items, 0..) |ctrl, idx| {
                if (ctrl.drained) {
                    to_remove.append(self.allocator, idx) catch {};
                }
            }
            {
                var j = to_remove.items.len;
                while (j > 0) {
                    j -= 1;
                    const idx = to_remove.items[j];
                    const ctrl = self.tracks.swapRemove(idx);
                    if (self.config.on_track_closed) |cb| cb();
                    ctrl.deinit(self.allocator);
                    self.allocator.destroy(ctrl);
                }
            }

            // Phase 2: mix active tracks and mark newly-drained ones.
            for (self.tracks.items) |ctrl| {
                const read_n = ctrl.readMixedChunk(buf, self.config.output) catch 0;
                if (read_n > 0) {
                    has_data = true;
                    active_tracks += 1;
                }
                if (ctrl.closed and ctrl.buffer.count() == 0) {
                    ctrl.drained = true;
                }
            }

            if (has_data) return buf.len;

            if (self.close_err) return null;
            if (self.close_write and self.tracks.items.len == 0) return null;
            if (self.config.auto_close and self.tracks.items.len == 0) return null;
            if (active_tracks == 0) return 0;
            return buf.len;
        }

        pub const Track = struct {
            internal: *TrackCtrl,
            pub fn write(self: *Track, format: Format, samples: []const i16) anyerror!void {
                try self.internal.write(format, samples);
            }
        };

        pub const TrackCtrl = struct {
            owner: *Self,
            label: []const u8,
            gain_bits: u32 = @bitCast(@as(f32, 1.0)),
            read_bytes_val: i64 = 0,
            fade_out_ms_val: i32 = 0,
            closed: bool = false,
            errored: bool = false,
            drained: bool = false,
            buffer: BufferType,
            track_handle: Track,

            fn init(self: *TrackCtrl, allocator: Allocator, owner: *Self, cfg: TrackConfig) !void {
                self.* = .{
                    .owner = owner,
                    .label = try allocator.dupe(u8, cfg.label),
                    .buffer = try BufferType.init(allocator, cfg.buffer_capacity),
                    .track_handle = undefined,
                };
                self.track_handle = .{ .internal = self };
                self.setGain(cfg.gain);
            }

            fn deinit(self: *TrackCtrl, allocator: Allocator) void {
                allocator.free(self.label);
                self.buffer.deinit();
            }

            pub fn setGain(self: *TrackCtrl, g: f32) void {
                @atomicStore(u32, &self.gain_bits, @bitCast(g), .release);
            }

            pub fn getGain(self: *TrackCtrl) f32 {
                return @bitCast(@atomicLoad(u32, &self.gain_bits, .acquire));
            }

            pub fn getLabel(self: *TrackCtrl) []const u8 {
                return self.label;
            }

            pub fn readBytes(self: *TrackCtrl) i64 {
                return @atomicLoad(i64, &self.read_bytes_val, .acquire);
            }

            pub fn setFadeOutDuration(self: *TrackCtrl, ms: u32) void {
                @atomicStore(i32, &self.fade_out_ms_val, @intCast(ms), .release);
            }

            pub fn closeWrite(self: *TrackCtrl) void {
                self.closed = true;
                self.buffer.close();
            }

            pub fn closeWriteWithSilence(self: *TrackCtrl, silence_ms: u32) void {
                const out = self.owner.config.output;
                const total = @as(usize, out.rate) * @as(usize, out.channelCount()) * silence_ms / 1000;
                var zeros: [1024]i16 = @splat(0);
                var remaining = total;
                while (remaining > 0) {
                    const n = @min(remaining, zeros.len);
                    _ = self.buffer.tryWrite(zeros[0..n]) catch break;
                    remaining -= n;
                }
                self.closed = true;
                self.buffer.close();
            }

            pub fn closeSelf(self: *TrackCtrl) void {
                const fade_ms = @atomicLoad(i32, &self.fade_out_ms_val, .acquire);
                if (fade_ms > 0) self.setGain(0);
                self.closed = true;
                self.buffer.close();
            }

            pub fn closeWithError(self: *TrackCtrl) void {
                self.closed = true;
                self.errored = true;
                self.buffer.close();
            }

            pub fn setGainLinearTo(self: *TrackCtrl, to: f32, _: u32) void {
                self.setGain(to);
            }

            fn write(self: *TrackCtrl, format: Format, samples: []const i16) anyerror!void {
                if (self.closed or self.errored) return error.Closed;
                const converted = try convertToOutput(self.owner.allocator, samples, format, self.owner.config.output);
                defer self.owner.allocator.free(converted);
                try self.buffer.write(converted);
            }

            fn readMixedChunk(self: *TrackCtrl, mixed: []i16, out_fmt: Format) !usize {
                _ = out_fmt;
                self.buffer.lock();
                defer self.buffer.unlock();

                const avail = self.buffer.readableSlice();
                if (avail.len == 0) return 0;
                const n = @min(mixed.len, avail.len);
                const gain = self.getGain();
                for (0..n) |i| {
                    const scaled = @as(f32, @floatFromInt(avail[i])) * gain;
                    const sum = @as(f32, @floatFromInt(mixed[i])) + scaled;
                    mixed[i] = @intFromFloat(std.math.clamp(sum, -32768.0, 32767.0));
                }
                self.buffer.consumeLocked(n);
                _ = @atomicRmw(i64, &self.read_bytes_val, .Add, @intCast(n * @sizeOf(i16)), .acq_rel);
                return n;
            }
        };

        fn convertToOutput(allocator: Allocator, in_samples: []const i16, in_fmt: Format, out_fmt: Format) ![]i16 {
            var work = try allocator.dupe(i16, in_samples);
            if (in_fmt.channels == .stereo and out_fmt.channels == .mono) {
                const mono_n = resampler_mod.stereoToMono(work);
                work = try allocator.realloc(work, mono_n);
            } else if (in_fmt.channels == .mono and out_fmt.channels == .stereo) {
                const out = try allocator.alloc(i16, work.len * 2);
                _ = resampler_mod.monoToStereo(work, out);
                allocator.free(work);
                work = out;
            }

            if (in_fmt.rate == out_fmt.rate) return work;

            var rs = try Resampler.init(allocator, .{
                .channels = out_fmt.channelCount(),
                .in_rate = in_fmt.rate,
                .out_rate = out_fmt.rate,
            });
            defer rs.deinit();

            const estimated = @max(work.len * out_fmt.rate / in_fmt.rate + 32, 64);
            const out = try allocator.alloc(i16, estimated);
            const r = try rs.process(work, out);
            allocator.free(work);
            return try allocator.realloc(out, r.out_produced);
        }
    };
}

// ---------------------------------------------------------------------------
// MixerBuffer tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const TestBuf = Buffer(runtime.std.Mutex, runtime.std.Condition);

test "mixer buffer write and read roundtrip" {
    var buf = try TestBuf.init(testing.allocator, 64);
    defer buf.deinit();

    const samples = [_]i16{ 10, 20, 30, 40 };
    try buf.write(&samples);
    try testing.expectEqual(@as(usize, 4), buf.count());

    var out: [8]i16 = undefined;
    const n = buf.read(&out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(i16, &samples, out[0..4]);
    try testing.expectEqual(@as(usize, 0), buf.count());
}

test "mixer buffer read returns partial when less data available" {
    var buf = try TestBuf.init(testing.allocator, 64);
    defer buf.deinit();

    const samples = [_]i16{ 1, 2 };
    try buf.write(&samples);

    var out: [8]i16 = undefined;
    const n = buf.read(&out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i16, 1), out[0]);
    try testing.expectEqual(@as(i16, 2), out[1]);
}

test "mixer buffer read on empty returns zero" {
    var buf = try TestBuf.init(testing.allocator, 64);
    defer buf.deinit();

    var out: [8]i16 = undefined;
    try testing.expectEqual(@as(usize, 0), buf.read(&out));
}

test "mixer buffer tryWrite respects capacity" {
    var buf = try TestBuf.init(testing.allocator, 4);
    defer buf.deinit();

    const samples = [_]i16{ 1, 2, 3, 4, 5, 6 };
    const n = try buf.tryWrite(&samples);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(@as(usize, 4), buf.count());

    try testing.expectEqual(@as(usize, 0), try buf.tryWrite(&samples));
}

test "mixer buffer close wakes writer and returns error" {
    var buf = try TestBuf.init(testing.allocator, 4);
    defer buf.deinit();

    const fill = [_]i16{ 1, 2, 3, 4 };
    try buf.write(&fill);

    buf.close();
    try testing.expectError(error.Closed, buf.write(&fill));
    try testing.expectError(error.Closed, buf.tryWrite(&fill));
}

test "mixer buffer readableSlice and consumeLocked" {
    var buf = try TestBuf.init(testing.allocator, 64);
    defer buf.deinit();

    const samples = [_]i16{ 10, 20, 30 };
    try buf.write(&samples);

    buf.lock();
    const slice = buf.readableSlice();
    try testing.expectEqual(@as(usize, 3), slice.len);
    try testing.expectEqual(@as(i16, 10), slice[0]);
    buf.consumeLocked(2);
    buf.unlock();

    try testing.expectEqual(@as(usize, 1), buf.count());
    var out: [4]i16 = undefined;
    try testing.expectEqual(@as(usize, 1), buf.read(&out));
    try testing.expectEqual(@as(i16, 30), out[0]);
}

test "mixer buffer write blocks then unblocks on read" {
    var buf = try TestBuf.init(testing.allocator, 4);
    defer buf.deinit();

    const fill = [_]i16{ 1, 2, 3, 4 };
    try buf.write(&fill);

    var done = std.atomic.Value(bool).init(false);

    const writer = try std.Thread.spawn(.{}, struct {
        fn run(b: *TestBuf, d: *std.atomic.Value(bool)) void {
            const extra = [_]i16{ 5, 6 };
            b.write(&extra) catch {};
            d.store(true, .release);
        }
    }.run, .{ &buf, &done });

    std.Thread.sleep(5 * std.time.ns_per_ms);
    try testing.expect(!done.load(.acquire));

    var out: [2]i16 = undefined;
    _ = buf.read(&out);

    writer.join();
    try testing.expect(done.load(.acquire));
    try testing.expectEqual(@as(usize, 4), buf.count());
}

// ---------------------------------------------------------------------------
// Mixer tests
// ---------------------------------------------------------------------------

const TestMx = Mixer(runtime.std.Mutex, runtime.std.Condition);

fn newMixer(config: TestMx.Config) TestMx {
    return TestMx.init(testing.allocator, config, runtime.std.Mutex.init());
}

fn readAll(mx: *TestMx, allocator: Allocator) ![]i16 {
    var out = std.ArrayList(i16).empty;
    defer out.deinit(allocator);

    var buf: [512]i16 = undefined;
    var idle_rounds: usize = 0;
    while (true) {
        const n_opt = mx.read(&buf);
        if (n_opt == null) break;
        const n = n_opt.?;
        if (n == 0) {
            idle_rounds += 1;
            if (idle_rounds > 2000) break;
            std.Thread.sleep(std.time.ns_per_ms);
            continue;
        }
        idle_rounds = 0;
        try out.appendSlice(allocator, buf[0..n]);
    }

    return try out.toOwnedSlice(allocator);
}

fn firstNonZero(samples: []const i16) bool {
    for (samples) |s| {
        if (s != 0) return true;
    }
    return false;
}

test "edge: read empty buffer returns zero" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 } });
    defer mx.deinit();

    var empty: [0]i16 = .{};
    try testing.expectEqual(@as(?usize, 0), mx.read(&empty));
}

test "edge: read with no track returns zero" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 } });
    defer mx.deinit();

    var out: [64]i16 = undefined;
    try testing.expectEqual(@as(?usize, 0), mx.read(&out));
}

test "edge: closeWrite then read returns null" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 } });
    defer mx.deinit();
    mx.closeWrite();

    var out: [64]i16 = undefined;
    try testing.expectEqual(@as(?usize, null), mx.read(&out));
}

test "edge: closeWithError then read returns null" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 } });
    defer mx.deinit();
    mx.closeWithError();

    var out: [64]i16 = undefined;
    try testing.expectEqual(@as(?usize, null), mx.read(&out));
}

test "edge: createTrack after closeWrite returns Closed" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 } });
    defer mx.deinit();
    mx.closeWrite();
    try testing.expectError(error.Closed, mx.createTrack(.{}));
}

test "edge: createTrack after closeWithError returns Closed" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 } });
    defer mx.deinit();
    mx.closeWithError();
    try testing.expectError(error.Closed, mx.createTrack(.{}));
}

test "track: defaults label and gain" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 } });
    defer mx.deinit();
    const h = try mx.createTrack(.{});

    try testing.expectEqualStrings("", h.ctrl.getLabel());
    try testing.expectEqual(@as(f32, 1.0), h.ctrl.getGain());
}

test "track: set and get gain" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 } });
    defer mx.deinit();
    const h = try mx.createTrack(.{});
    h.ctrl.setGain(0.25);
    try testing.expectEqual(@as(f32, 0.25), h.ctrl.getGain());
}

test "track: write after closeWrite returns Closed" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 } });
    defer mx.deinit();
    const h = try mx.createTrack(.{});
    h.ctrl.closeWrite();
    const data = [_]i16{1000} ** 8;
    try testing.expectError(error.Closed, h.track.write(.{ .rate = 16000 }, &data));
}

test "track: write after closeWithError returns Closed" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 } });
    defer mx.deinit();
    const h = try mx.createTrack(.{});
    h.ctrl.closeWithError();
    const data = [_]i16{1000} ** 8;
    try testing.expectError(error.Closed, h.track.write(.{ .rate = 16000 }, &data));
}

test "track: closeWriteWithSilence appends zeros" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 }, .auto_close = true });
    defer mx.deinit();
    const h = try mx.createTrack(.{});
    h.ctrl.closeWriteWithSilence(20);
    mx.closeWrite();

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);

    try testing.expect(mixed.len > 0);
    for (mixed[0..@min(mixed.len, 64)]) |s| {
        try testing.expectEqual(@as(i16, 0), s);
    }
}

test "track: closeSelf with fade duration sets gain to zero" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 } });
    defer mx.deinit();
    const h = try mx.createTrack(.{ .gain = 1.0 });
    h.ctrl.setFadeOutDuration(100);
    h.ctrl.closeSelf();
    try testing.expectEqual(@as(f32, 0.0), h.ctrl.getGain());
}

test "track: setGainLinearTo updates to target" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 } });
    defer mx.deinit();
    const h = try mx.createTrack(.{ .gain = 1.0 });
    h.ctrl.setGainLinearTo(0.4, 200);
    try testing.expectEqual(@as(f32, 0.4), h.ctrl.getGain());
}

test "lifecycle: destroyTrackCtrl removes active track safely" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 } });
    defer mx.deinit();
    const h = try mx.createTrack(.{});
    mx.destroyTrackCtrl(h.ctrl);

    var out: [64]i16 = undefined;
    try testing.expectEqual(@as(?usize, 0), mx.read(&out));
}

test "mix: single track passthrough and readBytes" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 }, .auto_close = true });
    defer mx.deinit();

    const h = try mx.createTrack(.{});
    const data = [_]i16{1000} ** 16;
    try h.track.write(.{ .rate = 16000 }, &data);
    h.ctrl.closeWrite();
    mx.closeWrite();

    var out: [16]i16 = undefined;
    const n = mx.read(&out) orelse 0;
    try testing.expectEqual(@as(usize, 16), n);
    for (out[0..16]) |s| try testing.expectEqual(@as(i16, 1000), s);

    // After the read() that drained the track, ctrl is still valid for one
    // more cycle — the two-phase removal only marks it as drained, and the
    // actual destroy happens on the *next* read().
    try testing.expectEqual(@as(i64, 32), h.ctrl.readBytes());
}

test "mix: two tracks exact sum" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 }, .auto_close = true });
    defer mx.deinit();

    const a = try mx.createTrack(.{ .label = "A" });
    const b = try mx.createTrack(.{ .label = "B" });

    const da = [_]i16{1000} ** 64;
    const db = [_]i16{2000} ** 64;
    try a.track.write(.{ .rate = 16000 }, &da);
    try b.track.write(.{ .rate = 16000 }, &db);
    a.ctrl.closeWrite();
    b.ctrl.closeWrite();
    mx.closeWrite();

    var out: [64]i16 = undefined;
    const n = mx.read(&out) orelse 0;
    try testing.expectEqual(@as(usize, 64), n);
    for (out[0..64]) |s| try testing.expectEqual(@as(i16, 3000), s);
}

test "mix: partial second track pads tail with first track" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 }, .auto_close = true });
    defer mx.deinit();

    const a = try mx.createTrack(.{});
    const b = try mx.createTrack(.{});
    const da = [_]i16{1000} ** 8;
    const db = [_]i16{2000} ** 4;
    try a.track.write(.{ .rate = 16000 }, &da);
    try b.track.write(.{ .rate = 16000 }, &db);
    a.ctrl.closeWrite();
    b.ctrl.closeWrite();
    mx.closeWrite();

    var out: [8]i16 = undefined;
    const n = mx.read(&out) orelse 0;
    try testing.expectEqual(@as(usize, 8), n);
    for (0..4) |i| try testing.expectEqual(@as(i16, 3000), out[i]);
    for (4..8) |i| try testing.expectEqual(@as(i16, 1000), out[i]);
}

test "mix: clipping boundary for large sums" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 }, .auto_close = true });
    defer mx.deinit();
    const a = try mx.createTrack(.{});
    const b = try mx.createTrack(.{});

    const da = [_]i16{30000} ** 32;
    const db = [_]i16{30000} ** 32;
    try a.track.write(.{ .rate = 16000 }, &da);
    try b.track.write(.{ .rate = 16000 }, &db);
    a.ctrl.closeWrite();
    b.ctrl.closeWrite();
    mx.closeWrite();

    var out: [32]i16 = undefined;
    const n = mx.read(&out) orelse 0;
    try testing.expectEqual(@as(usize, 32), n);
    for (out[0..32]) |s| try testing.expect(s >= 32760);
}

test "format: stereo input to mono output averages channels" {
    var mx = newMixer(.{ .output = .{ .rate = 16000, .channels = .mono }, .auto_close = true });
    defer mx.deinit();
    const h = try mx.createTrack(.{});

    const stereo = [_]i16{ 1000, 3000, 1000, 3000, 1000, 3000, 1000, 3000 };
    try h.track.write(.{ .rate = 16000, .channels = .stereo }, &stereo);
    h.ctrl.closeWrite();
    mx.closeWrite();

    var out: [8]i16 = undefined;
    const n = mx.read(&out) orelse 0;
    try testing.expectEqual(@as(usize, 8), n);
    for (0..4) |i| try testing.expectEqual(@as(i16, 2000), out[i]);
}

test "format: mono input to stereo output duplicates samples" {
    var mx = newMixer(.{ .output = .{ .rate = 16000, .channels = .stereo }, .auto_close = true });
    defer mx.deinit();
    const h = try mx.createTrack(.{});

    const mono = [_]i16{ 500, 1000, 1500, 2000 };
    try h.track.write(.{ .rate = 16000, .channels = .mono }, &mono);
    h.ctrl.closeWrite();
    mx.closeWrite();

    var out: [8]i16 = undefined;
    const n = mx.read(&out) orelse 0;
    try testing.expectEqual(@as(usize, 8), n);
    try testing.expectEqual(@as(i16, 500), out[0]);
    try testing.expectEqual(@as(i16, 500), out[1]);
    try testing.expectEqual(@as(i16, 1000), out[2]);
    try testing.expectEqual(@as(i16, 1000), out[3]);
}

test "format: resample 48k to 16k produces non-empty output" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 }, .auto_close = true });
    defer mx.deinit();
    const h = try mx.createTrack(.{});

    const src = [_]i16{1200} ** 4800;
    try h.track.write(.{ .rate = 48000 }, &src);
    h.ctrl.closeWrite();
    mx.closeWrite();

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    try testing.expect(mixed.len > 0);
    try testing.expect(firstNonZero(mixed));
}

test "callbacks: created and closed callbacks fire" {
    const Cb = struct {
        var created = std.atomic.Value(u32).init(0);
        var closed = std.atomic.Value(u32).init(0);
        fn onCreated() void {
            _ = created.fetchAdd(1, .acq_rel);
        }
        fn onClosed() void {
            _ = closed.fetchAdd(1, .acq_rel);
        }
    };
    Cb.created.store(0, .release);
    Cb.closed.store(0, .release);

    var mx = newMixer(.{
        .output = .{ .rate = 16000 },
        .auto_close = true,
        .on_track_created = Cb.onCreated,
        .on_track_closed = Cb.onClosed,
    });
    defer mx.deinit();

    const h = try mx.createTrack(.{});
    const d = [_]i16{400} ** 16;
    try h.track.write(.{ .rate = 16000 }, &d);
    h.ctrl.closeWrite();
    mx.closeWrite();

    const drained = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(drained);
    // trigger one extra read cycle to remove drained closed track
    var tmp: [16]i16 = undefined;
    _ = mx.read(&tmp);

    try testing.expectEqual(@as(u32, 1), Cb.created.load(.acquire));
    try testing.expect(Cb.closed.load(.acquire) >= 1);
}

test "concurrency: concurrent writes across tracks" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 }, .auto_close = true });
    defer mx.deinit();
    const fmt = TestMx.Format{ .rate = 16000 };

    const h1 = try mx.createTrack(.{});
    const h2 = try mx.createTrack(.{});
    const h3 = try mx.createTrack(.{});
    const d1 = [_]i16{1000} ** 320;
    const d2 = [_]i16{2000} ** 320;
    const d3 = [_]i16{3000} ** 320;

    const t1 = try std.Thread.spawn(.{}, struct {
        fn run(track: *TestMx.Track, ctrl: *TestMx.TrackCtrl, f: TestMx.Format, data: []const i16) void {
            track.write(f, data) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h1.track, h1.ctrl, fmt, @as([]const i16, &d1) });

    const t2 = try std.Thread.spawn(.{}, struct {
        fn run(track: *TestMx.Track, ctrl: *TestMx.TrackCtrl, f: TestMx.Format, data: []const i16) void {
            track.write(f, data) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h2.track, h2.ctrl, fmt, @as([]const i16, &d2) });

    const t3 = try std.Thread.spawn(.{}, struct {
        fn run(track: *TestMx.Track, ctrl: *TestMx.TrackCtrl, f: TestMx.Format, data: []const i16) void {
            track.write(f, data) catch {};
            ctrl.closeWrite();
        }
    }.run, .{ h3.track, h3.ctrl, fmt, @as([]const i16, &d3) });

    t1.join();
    t2.join();
    t3.join();
    mx.closeWrite();

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    try testing.expect(mixed.len > 0);
    try testing.expect(firstNonZero(mixed));
}

test "concurrency: createTrack from many threads" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 } });
    defer mx.deinit();

    const N = 16;
    var threads: [N]std.Thread = undefined;
    var success = std.atomic.Value(u32).init(0);

    for (0..N) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(mixer: *TestMx, succ: *std.atomic.Value(u32)) void {
                if (mixer.createTrack(.{})) |h| {
                    h.ctrl.closeWrite();
                    _ = succ.fetchAdd(1, .acq_rel);
                } else |_| {}
            }
        }.run, .{ &mx, &success });
    }
    for (&threads) |*t| t.join();

    try testing.expectEqual(@as(u32, N), success.load(.acquire));
}

test "concurrency: reader and writer progression" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 } });
    defer mx.deinit();
    const h = try mx.createTrack(.{});
    const fmt = TestMx.Format{ .rate = 16000 };
    const chunk = [_]i16{700} ** 64;

    const writer = try std.Thread.spawn(.{}, struct {
        fn run(mixer: *TestMx, track: *TestMx.Track, ctrl: *TestMx.TrackCtrl, f: TestMx.Format, c: []const i16) void {
            var i: usize = 0;
            while (i < 40) : (i += 1) {
                track.write(f, c) catch break;
                std.Thread.sleep(std.time.ns_per_ms);
            }
            ctrl.closeWrite();
            mixer.closeWrite();
        }
    }.run, .{ &mx, h.track, h.ctrl, fmt, @as([]const i16, &chunk) });

    const mixed = try readAll(&mx, testing.allocator);
    defer testing.allocator.free(mixed);
    writer.join();

    try testing.expect(mixed.len > 0);
    try testing.expect(firstNonZero(mixed));
}

test "concurrency: stalled track does not block active track output" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 } });
    defer mx.deinit();

    const stalled = try mx.createTrack(.{ .label = "stalled" });
    const active = try mx.createTrack(.{ .label = "active" });

    const data = [_]i16{2000} ** 64;
    try active.track.write(.{ .rate = 16000 }, &data);
    active.ctrl.closeWrite();

    var out: [64]i16 = undefined;
    const n = mx.read(&out) orelse 0;
    try testing.expectEqual(@as(usize, 64), n);
    for (out[0..64]) |s| try testing.expectEqual(@as(i16, 2000), s);

    stalled.ctrl.closeWrite();
    mx.closeWrite();
}

const MockSock = struct {
    allocator: Allocator,
    mutex: runtime.std.Mutex,
    bytes: std.ArrayList(u8),

    fn init(allocator: Allocator) MockSock {
        return .{
            .allocator = allocator,
            .mutex = runtime.std.Mutex.init(),
            .bytes = .empty,
        };
    }

    fn deinit(self: *MockSock) void {
        self.bytes.deinit(self.allocator);
        self.mutex.deinit();
    }

    fn writeSamples(self: *MockSock, samples: []const i16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (samples) |s| {
            const b: [2]u8 = @bitCast(s);
            try self.bytes.appendSlice(self.allocator, &b);
        }
    }

    fn decodeSamples(self: *MockSock, allocator: Allocator) ![]i16 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = self.bytes.items.len / 2;
        var out = try allocator.alloc(i16, n);
        for (0..n) |i| {
            out[i] = @bitCast([2]u8{ self.bytes.items[i * 2], self.bytes.items[i * 2 + 1] });
        }
        return out;
    }
};

test "concurrency: mock socket multi-route pipeline does not crash and outputs valid audio" {
    var mx = newMixer(.{ .output = .{ .rate = 16000 } });
    defer mx.deinit();
    var sock = MockSock.init(testing.allocator);
    defer sock.deinit();

    const fmt = TestMx.Format{ .rate = 16000 };
    const h1 = try mx.createTrack(.{ .label = "r1" });
    const h2 = try mx.createTrack(.{ .label = "r2" });
    const h3 = try mx.createTrack(.{ .label = "r3" });
    const d1 = [_]i16{1000} ** 128;
    const d2 = [_]i16{2000} ** 128;
    const d3 = [_]i16{3000} ** 128;

    var go = std.atomic.Value(bool).init(false);

    const reader = try std.Thread.spawn(.{}, struct {
        fn run(mixer: *TestMx, s: *MockSock) void {
            var buf: [256]i16 = undefined;
            var idle: usize = 0;
            while (true) {
                const n_opt = mixer.read(&buf);
                if (n_opt == null) break;
                const n = n_opt.?;
                if (n == 0) {
                    idle += 1;
                    if (idle > 2000) break;
                    std.Thread.sleep(std.time.ns_per_ms);
                    continue;
                }
                idle = 0;
                s.writeSamples(buf[0..n]) catch break;
            }
        }
    }.run, .{ &mx, &sock });

    const W = struct {
        fn run(track: *TestMx.Track, ctrl: *TestMx.TrackCtrl, f: TestMx.Format, data: []const i16, gate: *std.atomic.Value(bool)) void {
            while (!gate.load(.acquire)) {
                std.Thread.sleep(std.time.ns_per_ms);
            }
            var i: usize = 0;
            while (i < 12) : (i += 1) {
                track.write(f, data) catch break;
                std.Thread.sleep(std.time.ns_per_ms);
            }
            ctrl.closeWrite();
        }
    };

    const t1 = try std.Thread.spawn(.{}, W.run, .{ h1.track, h1.ctrl, fmt, @as([]const i16, &d1), &go });
    const t2 = try std.Thread.spawn(.{}, W.run, .{ h2.track, h2.ctrl, fmt, @as([]const i16, &d2), &go });
    const t3 = try std.Thread.spawn(.{}, W.run, .{ h3.track, h3.ctrl, fmt, @as([]const i16, &d3), &go });

    go.store(true, .release);

    t1.join();
    t2.join();
    t3.join();
    mx.closeWrite();
    reader.join();

    const samples = try sock.decodeSamples(testing.allocator);
    defer testing.allocator.free(samples);

    try testing.expect(samples.len > 0);
    try testing.expect(firstNonZero(samples));

    var max_abs: i16 = 0;
    for (samples) |s| {
        const a = if (s < 0) -s else s;
        if (a > max_abs) max_abs = a;
    }
    try testing.expect(max_abs >= 3000);
    try testing.expect(max_abs <= 32767);
}

test "soak(manual): mock socket multi-route stress" {
    const marker = std.process.getEnvVarOwned(testing.allocator, "MIXER_RUN_SOCK_SOAK") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(marker);

    var round: usize = 0;
    while (round < 80) : (round += 1) {
        var mx = newMixer(.{ .output = .{ .rate = 16000 } });
        defer mx.deinit();
        var sock = MockSock.init(testing.allocator);
        defer sock.deinit();

        const fmt = TestMx.Format{ .rate = 16000 };
        const h1 = try mx.createTrack(.{});
        const h2 = try mx.createTrack(.{});
        const d1 = [_]i16{800} ** 96;
        const d2 = [_]i16{1600} ** 96;

        const reader = try std.Thread.spawn(.{}, struct {
            fn run(mixer: *TestMx, s: *MockSock) void {
                var buf: [192]i16 = undefined;
                while (true) {
                    const n_opt = mixer.read(&buf);
                    if (n_opt == null) break;
                    const n = n_opt.?;
                    if (n == 0) {
                        std.Thread.sleep(std.time.ns_per_ms);
                        continue;
                    }
                    s.writeSamples(buf[0..n]) catch break;
                }
            }
        }.run, .{ &mx, &sock });

        const tw1 = try std.Thread.spawn(.{}, struct {
            fn run(track: *TestMx.Track, ctrl: *TestMx.TrackCtrl, f: TestMx.Format, data: []const i16) void {
                var i: usize = 0;
                while (i < 10) : (i += 1) track.write(f, data) catch break;
                ctrl.closeWrite();
            }
        }.run, .{ h1.track, h1.ctrl, fmt, @as([]const i16, &d1) });

        const tw2 = try std.Thread.spawn(.{}, struct {
            fn run(track: *TestMx.Track, ctrl: *TestMx.TrackCtrl, f: TestMx.Format, data: []const i16) void {
                var i: usize = 0;
                while (i < 10) : (i += 1) track.write(f, data) catch break;
                ctrl.closeWrite();
            }
        }.run, .{ h2.track, h2.ctrl, fmt, @as([]const i16, &d2) });

        tw1.join();
        tw2.join();
        mx.closeWrite();
        reader.join();

        const samples = try sock.decodeSamples(testing.allocator);
        defer testing.allocator.free(samples);
        try testing.expect(samples.len > 0);
    }
}
