//! 102-audio_engine — AEC loopback + music player on Korvo-2.
//!
//! Audio tasks:
//!   1. mic task   — audio_system.readFrame() → engine.write(mic, ref)
//!   2. engine     — internal capture loop (beamformer → processor → output)
//!   3. spk task   — engine.readSpeaker() → audio_system.writeSpk()
//!
//! Buttons (ADC):
//!   play  — toggle music playback
//!   set   — next song
//!   vol+  — speaker gain +3 dB
//!   vol-  — speaker gain -3 dB
//!   mute  — toggle mute
//!   vol-  long — toggle audio system on/off

const std = @import("std");
const embed = @import("embed");
const runtime = embed.runtime;
const hal = embed.hal;
const event = embed.pkg.event;
const app_mod = embed.pkg.app;
const audio = embed.pkg.audio;

pub const App = @import("state.zig");
const songs = @import("songs.zig");

const rom_printf = struct {
    extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;
}.esp_rom_printf;

fn gestureLogger(ctx: ?*anyopaque, ev: App.Event, emit_ctx: *anyopaque, emit: event.EmitFn(App.Event)) void {
    _ = ctx;
    switch (ev) {
        .button => |b| {
            _ = rom_printf("[btn] id=%s code=%d\n", b.id.ptr, @as(c_int, b.code));
        },
    }
    emit(emit_ctx, ev);
}

pub fn run(comptime hw: type, env: anytype) void {
    _ = env;

    const board_spec = @import("board_spec.zig");
    const Board = board_spec.Board(hw);

    const ChannelType = hw.Channel(App.Event);
    const SelectorType = hw.Selector(App.Event);
    const Thread = Board.thread.Type;
    const Adc = Board.adc;
    const AudioSystem = Board.audio_system;
    const Mutex = hw.sync.Mutex;
    const Cond = hw.sync.Condition;
    const Time = hw.time;

    const EngineType = audio.Engine(Mutex, Cond, Thread, Time);
    const MixerType = audio.Mixer(Mutex, Cond);
    const Format = audio.Format;
    const AdcBtnType = event.button.AdcButtonSet(Adc, Thread, Board.time, ChannelType, App.Event, "button");
    const GestureType = event.button.ButtonGesture(App.Event, "button", Board.time);
    const AppRt = app_mod.AppRuntime(App, SelectorType);

    const log: Board.log = .{};
    const time: Board.time = .{};
    const allocator = Board.allocator.system;

    // ── board init ──

    var board: Board = undefined;
    board.init() catch {
        log.err("board init failed");
        return;
    };
    defer board.deinit();

    // ── audio engine ──

    var eng = EngineType.init(allocator, .{
        .n_mics = AudioSystem.config.mic_count,
        .frame_size = 160,
        .sample_rate = AudioSystem.config.sample_rate,
        .speaker_ring_capacity = AudioSystem.config.sample_rate,
        .output_queue_capacity = AudioSystem.config.sample_rate,
        .input_queue_frames = 20,
    }, Mutex.init(), Time{}) catch {
        log.err("engine init failed");
        return;
    };
    defer eng.deinit();

    eng.start() catch {
        log.err("engine start failed");
        return;
    };

    // ── ADC buttons ──

    var adc_btn = AdcBtnType.init(allocator, &board.hal_board.adc_dev, time, Board.adc_button_config) catch {
        log.err("adc button init failed");
        return;
    };
    defer adc_btn.deinit();

    var gesture = GestureType.init(time, .{
        .multi_click_window_ms = 300,
        .long_press_ms = 800,
    });

    // ── flux runtime ──

    var selector = SelectorType.init(allocator) catch {
        log.err("selector init failed");
        return;
    };
    defer selector.deinit();

    var rt = AppRt.init(allocator, &selector, .{
        .poll_timeout_ms = 50,
    });
    defer rt.deinit();

    rt.register(adc_btn.channel) catch {
        log.err("register adc button failed");
        return;
    };
    rt.use(gesture.middleware());
    rt.use(.{ .ctx = null, .processFn = gestureLogger, .tickFn = null });

    // ── start audio_system ──

    board.hal_board.audio_system_dev.start() catch {
        log.err("audio_system start failed");
        return;
    };

    // ── spawn tasks ──

    const MicCtx = struct {
        audio_dev: *AudioSystem,
        engine: *EngineType,
        running: *const std.atomic.Value(bool),
    };

    const SpkCtx = struct {
        audio_dev: *AudioSystem,
        engine: *EngineType,
        running: *const std.atomic.Value(bool),
        frame_size: u32,
    };

    var task_running = std.atomic.Value(bool).init(true);

    var mic_ctx = MicCtx{
        .audio_dev = &board.hal_board.audio_system_dev,
        .engine = &eng,
        .running = &task_running,
    };

    var spk_ctx = SpkCtx{
        .audio_dev = &board.hal_board.audio_system_dev,
        .engine = &eng,
        .running = &task_running,
        .frame_size = 160,
    };

    var mic_thread = Thread.spawn(
        Board.thread.system,
        micTaskEntry(MicCtx),
        @ptrCast(&mic_ctx),
    ) catch {
        log.err("mic task start failed");
        return;
    };

    var spk_thread = Thread.spawn(
        Board.thread.system,
        spkTaskEntry(SpkCtx),
        @ptrCast(&spk_ctx),
    ) catch {
        log.err("spk task start failed");
        return;
    };

    adc_btn.start() catch {
        log.err("adc button start failed");
        return;
    };

    log.info("102-audio_engine started");

    // ── music state ──

    var current_melody_h: ?MixerType.TrackHandle = null;
    var current_bass_h: ?MixerType.TrackHandle = null;
    var melody_pcm: ?[]i16 = null;
    var bass_pcm: ?[]i16 = null;
    var last_song_gen: u8 = 0;
    const sample_rate = AudioSystem.config.sample_rate;
    const src_fmt = Format{ .rate = sample_rate, .channels = .mono };

    // ── main loop ──

    while (Board.isRunning()) {
        rt.tick();

        if (rt.isDirty()) {
            const state = rt.getState();
            const prev = rt.getPrev();

            // ── gain ──
            if (state.spk_gain_db != prev.spk_gain_db) {
                board.hal_board.audio_system_dev.setSpkGain(state.spk_gain_db) catch {};
                log.info("spk gain = {d} dB");
            }

            if (state.mic_gain_db != prev.mic_gain_db) {
                var ch: u8 = 0;
                while (ch < AudioSystem.config.mic_count) : (ch += 1) {
                    board.hal_board.audio_system_dev.setMicGain(ch, state.mic_gain_db) catch {};
                }
            }

            // ── mute ──
            if (state.muted != prev.muted) {
                board.hal_board.audio_system_dev.setSpkGain(if (state.muted) -127 else state.spk_gain_db) catch {};
                log.info(if (state.muted) "muted" else "unmuted");
            }

            // ── song switch (set button) ──
            if (state.song_gen != last_song_gen) {
                current_melody_h = null;
                current_bass_h = null;
                freePcm(&melody_pcm, allocator);
                freePcm(&bass_pcm, allocator);
                last_song_gen = state.song_gen;
            }

            // ── play / pause ──
            if (state.playing and !prev.playing) {
                if (current_melody_h == null) {
                    const song = songs.get(state.song_index);
                    log.info("playing song");

                    melody_pcm = songs.renderVoiceMono(allocator, song.bpm, song.melody, 0.55, sample_rate) catch null;
                    bass_pcm = songs.renderVoiceMono(allocator, song.bpm, song.bass, 0.45, sample_rate) catch null;

                    if (melody_pcm != null) {
                        current_melody_h = eng.createTrack(.{ .label = "melody", .gain = 1.0 }) catch null;
                        if (current_melody_h) |h| {
                            h.track.write(src_fmt, melody_pcm.?) catch {};
                            h.ctrl.closeWrite();
                        }
                    }
                    if (bass_pcm != null) {
                        current_bass_h = eng.createTrack(.{ .label = "bass", .gain = 1.0 }) catch null;
                        if (current_bass_h) |h| {
                            h.track.write(src_fmt, bass_pcm.?) catch {};
                            h.ctrl.closeWrite();
                        }
                    }
                }
            } else if (!state.playing and prev.playing) {
                current_melody_h = null;
                current_bass_h = null;
                freePcm(&melody_pcm, allocator);
                freePcm(&bass_pcm, allocator);
                log.info("paused");
            }

            // ── audio system on/off ──
            if (state.running != prev.running) {
                if (state.running) {
                    board.hal_board.audio_system_dev.start() catch {};
                    log.info("audio resumed");
                } else {
                    board.hal_board.audio_system_dev.stop() catch {};
                    log.info("audio paused");
                }
            }

            rt.commitFrame();
        }
    }

    // ── shutdown ──

    task_running.store(false, .release);
    adc_btn.stop();
    current_melody_h = null;
    current_bass_h = null;
    freePcm(&melody_pcm, allocator);
    freePcm(&bass_pcm, allocator);
    eng.stop();

    mic_thread.join();
    spk_thread.join();

    board.hal_board.audio_system_dev.stop() catch {};

    log.info("102-audio_engine stopped");
}

fn freePcm(pcm: *?[]i16, alloc: std.mem.Allocator) void {
    if (pcm.*) |p| {
        alloc.free(p);
        pcm.* = null;
    }
}

// ── task entry points ──

fn micTaskEntry(comptime Ctx: type) fn (?*anyopaque) void {
    return struct {
        fn entry(raw: ?*anyopaque) void {
            const ctx: *Ctx = @ptrCast(@alignCast(raw orelse return));
            while (ctx.running.load(.acquire)) {
                const frame = ctx.audio_dev.readFrame() catch continue;
                ctx.engine.write(&frame.mic, frame.ref);
            }
        }
    }.entry;
}

fn spkTaskEntry(comptime Ctx: type) fn (?*anyopaque) void {
    return struct {
        fn entry(raw: ?*anyopaque) void {
            const ctx: *Ctx = @ptrCast(@alignCast(raw orelse return));

            var spk_buf: [4096]i16 = undefined;
            const frame = spk_buf[0..ctx.frame_size];

            while (ctx.running.load(.acquire)) {
                const sn = ctx.engine.readSpeaker(frame);
                if (sn > 0) {
                    _ = ctx.audio_dev.writeSpk(frame[0..sn]) catch {};
                }
            }
        }
    }.entry;
}
