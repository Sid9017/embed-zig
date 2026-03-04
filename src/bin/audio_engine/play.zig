const std = @import("std");
const runtime = @import("runtime");
const portaudio = @import("portaudio");
const engine_mod = @import("engine");
const mixer_mod = @import("mixer");
const songs = @import("songs.zig");

const EngineType = engine_mod.Engine(runtime.std.Mutex, runtime.std.Condition, runtime.std.Thread, runtime.std.Time);
const MixerType = mixer_mod.Mixer(runtime.std.Mutex, runtime.std.Condition);
const Format = MixerType.Format;

pub const Config = struct {
    song_id: []const u8 = "twinkle_star",
    sample_rate: u32 = 16_000,
    src_sample_rate: u32 = 16_000,
    frame_size: u32 = 512,
};

pub fn run(allocator: std.mem.Allocator, cfg: Config) !void {
    const song = songs.find(cfg.song_id) orelse {
        std.debug.print("Unknown song: {s}\n", .{cfg.song_id});
        songs.printList();
        return error.UnknownSong;
    };

    std.debug.print(
        "[play] {s} src={d}Hz out={d}Hz mono\n",
        .{ song.name, cfg.src_sample_rate, cfg.sample_rate },
    );

    const melody_pcm = try songs.renderVoiceMono(allocator, song.bpm, song.melody, 0.55, cfg.src_sample_rate);
    defer allocator.free(melody_pcm);
    const bass_pcm = try songs.renderVoiceMono(allocator, song.bpm, song.bass, 0.45, cfg.src_sample_rate);
    defer allocator.free(bass_pcm);

    var eng = try EngineType.init(allocator, .{
        .sample_rate = cfg.sample_rate,
        .frame_size = cfg.frame_size,
        .speaker_ring_capacity = cfg.sample_rate,
        .output_queue_capacity = cfg.sample_rate,
        .input_queue_frames = 4,
    }, runtime.std.Mutex.init(), runtime.std.Time{});
    defer eng.deinit();

    try eng.start();

    const src_fmt = Format{ .rate = cfg.src_sample_rate, .channels = .mono };
    const melody_h = try eng.createTrack(.{ .label = "melody", .gain = 1.0 });
    const bass_h = try eng.createTrack(.{ .label = "bass", .gain = 1.0 });

    const t_melody = try std.Thread.spawn(.{}, writeTrack, .{ melody_h.track, melody_h.ctrl, src_fmt, melody_pcm });
    const t_bass = try std.Thread.spawn(.{}, writeTrack, .{ bass_h.track, bass_h.ctrl, src_fmt, bass_pcm });

    var audio = try portaudio.AudioIO.init();
    defer audio.deinit();
    try audio.openDefaultOutput(.{
        .channels = 1,
        .sample_rate = @as(f64, @floatFromInt(cfg.sample_rate)),
        .frames_per_buffer = cfg.frame_size,
    });
    try audio.start();
    defer audio.stop() catch {};

    var buf: [4096]i16 = undefined;
    const frame = buf[0..cfg.frame_size];
    var idle: usize = 0;
    const timeout_ns: u64 = 50 * std.time.ns_per_ms;

    while (true) {
        const n = eng.readRef(frame, timeout_ns);
        if (n == 0) {
            idle += 1;
            if (idle > 60) break;
            continue;
        }
        idle = 0;
        if (!try audio.pollWritable(200)) return error.TimedOut;
        try audio.writeI16(frame[0..n]);
    }

    t_melody.join();
    t_bass.join();
    eng.stop();
    std.debug.print("[play] done.\n", .{});
}

fn writeTrack(track: *MixerType.Track, ctrl: *MixerType.TrackCtrl, fmt: Format, pcm: []const i16) void {
    track.write(fmt, pcm) catch {};
    ctrl.closeWrite();
}
