//! 102-audio_engine — State + reducer.
//!
//! Buttons (names match board_spec.adc_buttons fields):
//!   play     click → toggle playing
//!   set      click → next song
//!   vol_up   click → spk_gain_db += 3
//!   vol_down click → spk_gain_db -= 3
//!   mute     click → toggle muted
//!   vol_down long  → toggle audio system running

const std = @import("std");
const embed = @import("embed");
const event = embed.pkg.event;
const songs = @import("songs.zig");

pub const State = struct {
    spk_gain_db: i8 = 0,
    mic_gain_db: i8 = 24,
    muted: bool = false,
    playing: bool = false,
    song_index: u8 = 0,
    song_gen: u8 = 0,
    running: bool = true,
};

pub const InputSpec = .{
    .adc_btn = event.button.RawEvent,
};

pub const OutputSpec = .{
    .gesture = event.button.GestureEvent,
};

/// Handle a gesture event identified by event.button id.
pub fn handleGesture(state: *State, id: []const u8, g: event.button.GestureEvent) void {
    switch (g) {
        .click => |count| handleClick(state, id, count),
        .long_press => |_| {
            if (std.mem.eql(u8, id, "vol_down")) {
                state.running = !state.running;
            }
        },
    }
}

fn handleClick(state: *State, id: []const u8, count: u16) void {
    _ = count;
    if (std.mem.eql(u8, id, "play")) {
        state.playing = !state.playing;
    } else if (std.mem.eql(u8, id, "set")) {
        state.song_index = @intCast((@as(u16, state.song_index) + 1) % songs.catalog.len);
        state.song_gen +%= 1;
        state.playing = true;
    } else if (std.mem.eql(u8, id, "vol_up")) {
        state.spk_gain_db = @min(24, state.spk_gain_db +| 3);
    } else if (std.mem.eql(u8, id, "vol_down")) {
        state.spk_gain_db = @max(-12, state.spk_gain_db -| 3);
    } else if (std.mem.eql(u8, id, "mute")) {
        state.muted = !state.muted;
    }
}
