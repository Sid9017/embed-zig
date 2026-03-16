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
const button = event.button;
const audio = embed.pkg.audio;

pub const App = @import("state.zig");
const songs = @import("songs.zig");

pub fn run(comptime hw: type, env: anytype) void {
    _ = env;

    const board_spec = @import("board_spec.zig");
    const Board = board_spec.Board(hw);

    const Time = Board.time;
    const Thread = Board.thread.Type;
    const Adc = Board.adc;
    const AudioSystem = Board.audio_system;
    const Mutex = hw.sync.Mutex;
    const Cond = hw.sync.Condition;

    const MyBus = event.Bus(App.InputSpec, App.OutputSpec, Board.channel);
    const AdcBtnType = button.AdcButtonSet(Adc, Time);
    const Gesture = button.ButtonGesture(Time, .{
        .multi_click_window_ms = 300,
        .long_press_ms = 800,
    });

    const EngineType = audio.Engine(Mutex, Cond, Thread, Time);
    const MixerType = audio.Mixer(Mutex, Cond);
    const Format = audio.Format;

    const log: Board.log = .{};
    const time: Time = .{};
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

    // ── event bus ──

    var bus = MyBus.init(allocator, 16) catch {
        log.err("bus init failed");
        return;
    };
    defer bus.deinit();

    // ── ADC buttons ──

    var adc_btn = AdcBtnType.init(
        &board.hal_board.adc_dev,
        time,
        .{ .ranges = Board.adc_button_config.ranges },
        bus.Injector(.adc_btn),
    );

    // ── middleware: gesture recognizer ──

    const gesture_mw = MyBus.Processor(.adc_btn, .gesture, Gesture).init(allocator) catch {
        log.err("gesture middleware init failed");
        return;
    };
    defer gesture_mw.deinit();
    bus.use(gesture_mw);

    // ── middleware: logger ──

    const log_mw = MyBus.Logger(Board.log).init(allocator) catch {
        log.err("logger middleware init failed");
        return;
    };
    defer log_mw.deinit();
    bus.use(log_mw);

    // ── start audio_system ──

    board.hal_board.audio_system_dev.start() catch {
        log.err("audio_system start failed");
        return;
    };

    // ── spawn tasks ──

    var task_running = std.atomic.Value(bool).init(true);

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

    const Runners = struct {
        fn runBtn(ctx: ?*anyopaque) void {
            const self: *AdcBtnType = @ptrCast(@alignCast(ctx orelse return));
            self.run();
        }
        fn runBus(ctx: ?*anyopaque) void {
            const b: *MyBus = @ptrCast(@alignCast(ctx orelse return));
            b.run();
        }
        fn runTick(ctx: ?*anyopaque) void {
            const b: *MyBus = @ptrCast(@alignCast(ctx orelse return));
            const t: Time = .{};
            b.tick(t, 50);
        }
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

    var btn_thread = Thread.spawn(
        Board.thread.user,
        Runners.runBtn,
        @ptrCast(&adc_btn),
    ) catch {
        log.err("adc button thread start failed");
        return;
    };

    var bus_thread = Thread.spawn(
        Board.thread.system,
        Runners.runBus,
        @ptrCast(&bus),
    ) catch {
        log.err("bus run thread start failed");
        return;
    };

    var tick_thread = Thread.spawn(
        Board.thread.system,
        Runners.runTick,
        @ptrCast(&bus),
    ) catch {
        log.err("tick thread start failed");
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

    var state = App.State{};
    var prev = state;

    // ── main loop ──

    while (Board.isRunning()) {
        const r = bus.recv() catch break;
        if (!r.ok) break;

        switch (r.value) {
            .gesture => |g| App.handleGesture(&state, g.id, g.gesture),
            .input => {},
        }

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

        prev = state;
    }

    // ── shutdown ──

    task_running.store(false, .release);
    adc_btn.stop();
    bus.stop();
    current_melody_h = null;
    current_bass_h = null;
    freePcm(&melody_pcm, allocator);
    freePcm(&bass_pcm, allocator);
    eng.stop();

    mic_thread.join();
    spk_thread.join();
    btn_thread.join();
    bus_thread.join();
    tick_thread.join();

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
