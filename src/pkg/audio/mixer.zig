//! Multi-track PCM mixer.
//!
//! Compared with legacy `embed-zig/lib/pkg/audio/src/mixer.zig`, this migration
//! baseline keeps the core external behavior:
//! - track create/write/read/close flow
//! - gain + label + readBytes accounting
//! - per-track format conversion through resampler helpers
//! while using a simpler in-memory queue strategy for deterministic bring-up.

const std = @import("std");
const embed = @import("../../mod.zig");
const resampler_mod = @import("resampler.zig");

const Allocator = std.mem.Allocator;
const Resampler = resampler_mod.Resampler;

/// Bounded sample buffer for mixer tracks.
/// Write blocks when the buffer is at capacity (backpressure).
/// Read is non-blocking — returns however many samples are available.
pub fn Buffer(comptime Runtime: type) type {
    comptime _ = embed.runtime.is(Runtime);

    return struct {
        const Self = @This();

        allocator: Allocator,
        items: []i16,
        len: usize,
        capacity: usize,
        closed: bool,
        mutex: Runtime.Mutex,
        not_full: Runtime.Condition,

        pub fn init(allocator: Allocator, capacity: usize) Allocator.Error!Self {
            const items = try allocator.alloc(i16, capacity);
            return .{
                .allocator = allocator,
                .items = items,
                .len = 0,
                .capacity = capacity,
                .closed = false,
                .mutex = Runtime.Mutex.init(),
                .not_full = Runtime.Condition.init(),
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

pub fn Mixer(comptime Runtime: type) type {
    comptime _ = embed.runtime.is(Runtime);

    const BufferType = Buffer(Runtime);

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
        mutex: Runtime.Mutex,
        close_write: bool = false,
        close_err: bool = false,
        tracks: std.ArrayList(*TrackCtrl),

        pub fn init(allocator: Allocator, config: Config, mutex: Runtime.Mutex) Self {
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
            read_bytes_val: usize = 0,
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

            pub fn readBytes(self: *TrackCtrl) usize {
                return @atomicLoad(usize, &self.read_bytes_val, .acquire);
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
                _ = @atomicRmw(usize, &self.read_bytes_val, .Add, n * @sizeOf(i16), .acq_rel);
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
