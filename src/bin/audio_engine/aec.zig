const std = @import("std");
const runtime = @import("runtime");
const portaudio = @import("portaudio");
const engine_mod = @import("engine");
const mixer_mod = @import("mixer");
const songs = @import("songs.zig");
const processor_mod = @import("processor.zig");

const EngineType = engine_mod.Engine(runtime.std.Mutex, runtime.std.Condition, runtime.std.Thread, runtime.std.Time);
const MixerType = mixer_mod.Mixer(runtime.std.Mutex, runtime.std.Condition);
const Format = MixerType.Format;

pub const Config = struct {
    song_id: []const u8 = "twinkle_star",
    sample_rate: u32 = 16_000,
    frame_size: u32 = 160,
    record_seconds: u32 = 5,
};

pub fn run(allocator: std.mem.Allocator, cfg: Config) !void {
    const song = songs.find(cfg.song_id) orelse {
        std.debug.print("Unknown song: {s}\n", .{cfg.song_id});
        songs.printList();
        return error.UnknownSong;
    };

    std.debug.print("[aec] {s} rate={d}Hz frame={d} record={d}s\n", .{
        song.name, cfg.sample_rate, cfg.frame_size, cfg.record_seconds,
    });

    var aec_ns = try processor_mod.SpeexAecNs.create(cfg.frame_size, cfg.sample_rate);

    var eng = try EngineType.init(allocator, .{
        .sample_rate = cfg.sample_rate,
        .frame_size = cfg.frame_size,
        .speaker_ring_capacity = cfg.sample_rate * 2,
        .output_queue_capacity = cfg.sample_rate * 2,
        .input_queue_frames = 20,
    }, runtime.std.Mutex.init(), runtime.std.Time{});
    defer eng.deinit();

    eng.setProcessor(aec_ns.processor());
    try eng.start();

    // ── Open duplex stream (single stream = hardware-aligned I/O) ─────

    var pa = try portaudio.AudioIO.init();
    defer pa.deinit();

    const rate_f: f64 = @floatFromInt(cfg.sample_rate);
    try pa.openDefaultDuplex(
        .{ .channels = 1, .sample_rate = rate_f, .frames_per_buffer = cfg.frame_size },
        .{ .channels = 1, .sample_rate = rate_f, .frames_per_buffer = cfg.frame_size },
    );
    try pa.start();

    const latency = pa.getLatencyInfo() catch |e| blk: {
        std.debug.print("[aec] warning: could not get latency info: {}\n", .{e});
        break :blk portaudio.AudioIO.LatencyInfo{
            .input_latency_ms = 0,
            .output_latency_ms = 0,
            .sample_rate = rate_f,
        };
    };
    std.debug.print("[aec] duplex latency: in={d:.1}ms out={d:.1}ms\n", .{
        latency.input_latency_ms, latency.output_latency_ms,
    });

    // ── Phase 1: play music + record mic (duplex-aligned) ─────────────

    std.debug.print("[aec] phase 1: playing + recording {d}s ...\n", .{cfg.record_seconds});

    const src_fmt = Format{ .rate = cfg.sample_rate, .channels = .mono };
    const melody_pcm = try songs.renderVoiceMono(allocator, song.bpm, song.melody, 0.55, cfg.sample_rate);
    defer allocator.free(melody_pcm);
    const bass_pcm = try songs.renderVoiceMono(allocator, song.bpm, song.bass, 0.45, cfg.sample_rate);
    defer allocator.free(bass_pcm);

    const melody_h = try eng.createTrack(.{ .label = "melody", .gain = 1.0 });
    const bass_h = try eng.createTrack(.{ .label = "bass", .gain = 1.0 });
    const t_melody = try std.Thread.spawn(.{}, writeTrack, .{ melody_h.track, melody_h.ctrl, src_fmt, melody_pcm });
    const t_bass = try std.Thread.spawn(.{}, writeTrack, .{ bass_h.track, bass_h.ctrl, src_fmt, bass_pcm });

    // c_allocator avoids page_allocator/GPA unmapping pages on realloc,
    // which would invalidate slices shared with other threads.
    const rec_alloc = std.heap.c_allocator;
    const record_capacity = cfg.sample_rate * cfg.record_seconds;
    var record_buf = try std.ArrayList(i16).initCapacity(rec_alloc, record_capacity);
    defer record_buf.deinit(rec_alloc);

    const total_frames = (cfg.sample_rate * cfg.record_seconds) / cfg.frame_size;
    var spk_buf: [4096]i16 = undefined;
    const spk_frame = spk_buf[0..cfg.frame_size];
    var mic_in: [4096]i16 = undefined;
    const mic_frame = mic_in[0..cfg.frame_size];

    for (0..total_frames) |_| {
        // Read speaker data from engine mixer (ref signal)
        const n = eng.readRef(spk_frame, 20 * std.time.ns_per_ms);
        const out_slice = if (n > 0) spk_frame[0..n] else blk: {
            @memset(spk_frame, 0);
            break :blk spk_frame;
        };

        // Duplex: write speaker output then read mic input — same hardware frame
        pa.writeI16(out_slice) catch {};
        pa.readI16(mic_frame) catch continue;

        record_buf.appendSlice(rec_alloc, mic_frame) catch break;
    }

    melody_h.ctrl.closeWrite();
    bass_h.ctrl.closeWrite();
    t_melody.join();
    t_bass.join();

    pa.stop() catch {};

    std.debug.print("[aec] recorded {d} samples ({d:.1}s)\n", .{
        record_buf.items.len,
        @as(f64, @floatFromInt(record_buf.items.len)) / @as(f64, @floatFromInt(cfg.sample_rate)),
    });

    // ── Transition: drain engine buffers, keep running ────────────────

    eng.drainBuffers();
    std.debug.print("[aec] buffers drained, starting phase 2\n", .{});

    // ── Phase 2: play same song as ref + feed recorded mic → AEC ──────

    const melody_pcm2 = try songs.renderVoiceMono(allocator, song.bpm, song.melody, 0.55, cfg.sample_rate);
    defer allocator.free(melody_pcm2);
    const bass_pcm2 = try songs.renderVoiceMono(allocator, song.bpm, song.bass, 0.45, cfg.sample_rate);
    defer allocator.free(bass_pcm2);

    const mel2 = try eng.createTrack(.{ .label = "melody2", .gain = 1.0 });
    const bas2 = try eng.createTrack(.{ .label = "bass2", .gain = 1.0 });
    const t_mel2 = try std.Thread.spawn(.{}, writeTrack, .{ mel2.track, mel2.ctrl, src_fmt, melody_pcm2 });
    const t_bas2 = try std.Thread.spawn(.{}, writeTrack, .{ bas2.track, bas2.ctrl, src_fmt, bass_pcm2 });

    // Re-open duplex for phase 2 output + silence input
    try pa.openDefaultDuplex(
        .{ .channels = 1, .sample_rate = rate_f, .frames_per_buffer = cfg.frame_size },
        .{ .channels = 1, .sample_rate = rate_f, .frames_per_buffer = cfg.frame_size },
    );
    try pa.start();

    std.debug.print("[aec] phase 2: playing processed recording ...\n", .{});

    const mic_feeder = try std.Thread.spawn(.{}, micFeederFn, .{
        &eng, @as([]const i16, record_buf.items), cfg.frame_size, cfg.sample_rate,
    });

    // Read AEC-processed output from engine, write to speaker via duplex
    var out_buf: [4096]i16 = undefined;
    const out_frame = out_buf[0..cfg.frame_size];
    var idle: usize = 0;
    const timeout_ns: u64 = 50 * std.time.ns_per_ms;

    while (true) {
        const rn = eng.timedRead(out_frame, timeout_ns);
        if (rn > 0) {
            idle = 0;
            pa.writeI16(out_frame[0..rn]) catch {};
            // Read and discard mic input to keep duplex stream flowing
            pa.readI16(mic_frame) catch {};
        } else {
            idle += 1;
            if (idle > 60) break;
        }
    }

    mic_feeder.join();
    t_mel2.join();
    t_bas2.join();
    pa.stop() catch {};
    eng.stop();

    std.debug.print("[aec] done.\n", .{});
}

fn writeTrack(track: *MixerType.Track, ctrl: *MixerType.TrackCtrl, fmt: Format, pcm: []const i16) void {
    track.write(fmt, pcm) catch {};
    ctrl.closeWrite();
}

fn micFeederFn(
    eng: *EngineType,
    recorded: []const i16,
    frame_size: u32,
    sample_rate: u32,
) void {
    const interval_ns = @as(u64, frame_size) * std.time.ns_per_s / @as(u64, sample_rate);
    var mic_buf: [4096]i16 = undefined;
    const mic_frame = mic_buf[0..frame_size];
    var matrix = [_][]const i16{mic_frame};

    var offset: usize = 0;
    while (offset + frame_size <= recorded.len) {
        @memcpy(mic_frame, recorded[offset .. offset + frame_size]);
        eng.write(&matrix, null);
        offset += frame_size;
        std.Thread.sleep(interval_ns);
    }
}
