const std = @import("std");

const Whole: f64 = 4.0;
const Half: f64 = 2.0;
const Quarter: f64 = 1.0;

const Rest = 0.0;
const C3 = 131.0;
const D3 = 147.0;
const E3 = 165.0;
const F3 = 175.0;
const Fs3 = 185.0;
const G3 = 196.0;
const A3 = 220.0;
const B3 = 247.0;
const C4 = 262.0;
const D4 = 294.0;
const E4 = 330.0;
const F4 = 349.0;
const G4 = 392.0;
const A4 = 440.0;
const B4 = 494.0;
const Cs5 = 554.0;
const D5 = 587.0;
const E5 = 659.0;
const Fs5 = 740.0;
const G5 = 784.0;
const A5 = 880.0;

pub const Note = struct {
    freq_hz: f64,
    beats: f64,
};

pub const Song = struct {
    id: []const u8,
    name: []const u8,
    bpm: u32,
    melody: []const Note,
    bass: []const Note,
};

const twinkle_melody = [_]Note{
    .{ .freq_hz = C4, .beats = Quarter }, .{ .freq_hz = C4, .beats = Quarter }, .{ .freq_hz = G4, .beats = Quarter }, .{ .freq_hz = G4, .beats = Quarter },
    .{ .freq_hz = A4, .beats = Quarter }, .{ .freq_hz = A4, .beats = Quarter }, .{ .freq_hz = G4, .beats = Half },    .{ .freq_hz = F4, .beats = Quarter },
    .{ .freq_hz = F4, .beats = Quarter }, .{ .freq_hz = E4, .beats = Quarter }, .{ .freq_hz = E4, .beats = Quarter }, .{ .freq_hz = D4, .beats = Quarter },
    .{ .freq_hz = D4, .beats = Quarter }, .{ .freq_hz = C4, .beats = Half },    .{ .freq_hz = G4, .beats = Quarter }, .{ .freq_hz = G4, .beats = Quarter },
    .{ .freq_hz = F4, .beats = Quarter }, .{ .freq_hz = F4, .beats = Quarter }, .{ .freq_hz = E4, .beats = Quarter }, .{ .freq_hz = E4, .beats = Quarter },
    .{ .freq_hz = D4, .beats = Half },    .{ .freq_hz = G4, .beats = Quarter }, .{ .freq_hz = G4, .beats = Quarter }, .{ .freq_hz = F4, .beats = Quarter },
    .{ .freq_hz = F4, .beats = Quarter }, .{ .freq_hz = E4, .beats = Quarter }, .{ .freq_hz = E4, .beats = Quarter }, .{ .freq_hz = D4, .beats = Half },
    .{ .freq_hz = C4, .beats = Quarter }, .{ .freq_hz = C4, .beats = Quarter }, .{ .freq_hz = G4, .beats = Quarter }, .{ .freq_hz = G4, .beats = Quarter },
    .{ .freq_hz = A4, .beats = Quarter }, .{ .freq_hz = A4, .beats = Quarter }, .{ .freq_hz = G4, .beats = Half },    .{ .freq_hz = F4, .beats = Quarter },
    .{ .freq_hz = F4, .beats = Quarter }, .{ .freq_hz = E4, .beats = Quarter }, .{ .freq_hz = E4, .beats = Quarter }, .{ .freq_hz = D4, .beats = Quarter },
    .{ .freq_hz = D4, .beats = Quarter }, .{ .freq_hz = C4, .beats = Half },
};

const twinkle_bass = [_]Note{
    .{ .freq_hz = C3, .beats = Quarter }, .{ .freq_hz = E3, .beats = Quarter }, .{ .freq_hz = G3, .beats = Quarter }, .{ .freq_hz = E3, .beats = Quarter },
    .{ .freq_hz = F3, .beats = Quarter }, .{ .freq_hz = A3, .beats = Quarter }, .{ .freq_hz = C3, .beats = Half },    .{ .freq_hz = F3, .beats = Quarter },
    .{ .freq_hz = A3, .beats = Quarter }, .{ .freq_hz = C3, .beats = Quarter }, .{ .freq_hz = E3, .beats = Quarter }, .{ .freq_hz = G3, .beats = Quarter },
    .{ .freq_hz = B3, .beats = Quarter }, .{ .freq_hz = C3, .beats = Half },    .{ .freq_hz = C3, .beats = Quarter }, .{ .freq_hz = E3, .beats = Quarter },
    .{ .freq_hz = F3, .beats = Quarter }, .{ .freq_hz = A3, .beats = Quarter }, .{ .freq_hz = C3, .beats = Quarter }, .{ .freq_hz = E3, .beats = Quarter },
    .{ .freq_hz = G3, .beats = Half },    .{ .freq_hz = C3, .beats = Quarter }, .{ .freq_hz = E3, .beats = Quarter }, .{ .freq_hz = F3, .beats = Quarter },
    .{ .freq_hz = A3, .beats = Quarter }, .{ .freq_hz = C3, .beats = Quarter }, .{ .freq_hz = E3, .beats = Quarter }, .{ .freq_hz = G3, .beats = Half },
    .{ .freq_hz = C3, .beats = Quarter }, .{ .freq_hz = E3, .beats = Quarter }, .{ .freq_hz = G3, .beats = Quarter }, .{ .freq_hz = E3, .beats = Quarter },
    .{ .freq_hz = F3, .beats = Quarter }, .{ .freq_hz = A3, .beats = Quarter }, .{ .freq_hz = C3, .beats = Half },    .{ .freq_hz = F3, .beats = Quarter },
    .{ .freq_hz = A3, .beats = Quarter }, .{ .freq_hz = C3, .beats = Quarter }, .{ .freq_hz = E3, .beats = Quarter }, .{ .freq_hz = G3, .beats = Quarter },
    .{ .freq_hz = B3, .beats = Quarter }, .{ .freq_hz = C3, .beats = Half },
};

const canon_melody = [_]Note{
    .{ .freq_hz = Fs5, .beats = Half },    .{ .freq_hz = E5, .beats = Half },     .{ .freq_hz = D5, .beats = Half },     .{ .freq_hz = Cs5, .beats = Half },
    .{ .freq_hz = B4, .beats = Half },     .{ .freq_hz = A4, .beats = Half },     .{ .freq_hz = B4, .beats = Half },     .{ .freq_hz = Cs5, .beats = Half },
    .{ .freq_hz = D5, .beats = Quarter },  .{ .freq_hz = Fs5, .beats = Quarter }, .{ .freq_hz = A5, .beats = Quarter },  .{ .freq_hz = G5, .beats = Quarter },
    .{ .freq_hz = Fs5, .beats = Quarter }, .{ .freq_hz = D5, .beats = Quarter },  .{ .freq_hz = Fs5, .beats = Quarter }, .{ .freq_hz = E5, .beats = Quarter },
    .{ .freq_hz = D5, .beats = Quarter },  .{ .freq_hz = B4, .beats = Quarter },  .{ .freq_hz = D5, .beats = Quarter },  .{ .freq_hz = A4, .beats = Quarter },
    .{ .freq_hz = G4, .beats = Quarter },  .{ .freq_hz = B4, .beats = Quarter },  .{ .freq_hz = A4, .beats = Quarter },  .{ .freq_hz = G4, .beats = Quarter },
    .{ .freq_hz = Fs3, .beats = Quarter }, .{ .freq_hz = D3, .beats = Quarter },  .{ .freq_hz = E4, .beats = Quarter },  .{ .freq_hz = Fs3, .beats = Quarter },
    .{ .freq_hz = G4, .beats = Quarter },  .{ .freq_hz = A4, .beats = Quarter },  .{ .freq_hz = B4, .beats = Quarter },  .{ .freq_hz = G4, .beats = Quarter },
    .{ .freq_hz = Fs3, .beats = Half },    .{ .freq_hz = D5, .beats = Half },     .{ .freq_hz = D5, .beats = Whole },
};

const canon_bass = [_]Note{
    .{ .freq_hz = D3, .beats = Half }, .{ .freq_hz = A3, .beats = Half }, .{ .freq_hz = B3, .beats = Half },  .{ .freq_hz = Fs3, .beats = Half },
    .{ .freq_hz = G3, .beats = Half }, .{ .freq_hz = D3, .beats = Half }, .{ .freq_hz = G3, .beats = Half },  .{ .freq_hz = A3, .beats = Half },
    .{ .freq_hz = D3, .beats = Half }, .{ .freq_hz = A3, .beats = Half }, .{ .freq_hz = B3, .beats = Half },  .{ .freq_hz = Fs3, .beats = Half },
    .{ .freq_hz = G3, .beats = Half }, .{ .freq_hz = D3, .beats = Half }, .{ .freq_hz = G3, .beats = Half },  .{ .freq_hz = A3, .beats = Half },
    .{ .freq_hz = D3, .beats = Half }, .{ .freq_hz = A3, .beats = Half }, .{ .freq_hz = B3, .beats = Half },  .{ .freq_hz = Fs3, .beats = Half },
    .{ .freq_hz = G3, .beats = Half }, .{ .freq_hz = D3, .beats = Half }, .{ .freq_hz = D3, .beats = Whole },
};

pub const catalog = [_]Song{
    .{ .id = "twinkle_star", .name = "Twinkle Star", .bpm = 100, .melody = &twinkle_melody, .bass = &twinkle_bass },
    .{ .id = "canon", .name = "Canon", .bpm = 60, .melody = &canon_melody, .bass = &canon_bass },
};

pub fn find(song_id: []const u8) ?Song {
    for (catalog) |s| {
        if (std.mem.eql(u8, s.id, song_id)) return s;
    }
    return null;
}

pub fn printList() void {
    std.debug.print("Available songs:\n", .{});
    for (catalog, 0..) |s, i| {
        std.debug.print("  {d}. {s} ({s})\n", .{ i + 1, s.id, s.name });
    }
}

pub fn beatToMs(bpm: u32, beats: f64) u32 {
    const ms = beats * 60_000.0 / @as(f64, @floatFromInt(bpm));
    return @intFromFloat(ms);
}

pub fn msToFrames(sample_rate: u32, ms: u32) usize {
    const rate: usize = @intCast(sample_rate);
    return @max(@as(usize, 1), (rate * @as(usize, @intCast(ms)) + 999) / 1000);
}

pub fn renderVoiceMono(allocator: std.mem.Allocator, bpm: u32, notes: []const Note, amp: f64, sample_rate: u32) ![]i16 {
    var total_frames: usize = 0;
    for (notes) |n| total_frames += msToFrames(sample_rate, beatToMs(bpm, n.beats));

    const out = try allocator.alloc(i16, total_frames);
    var write_idx: usize = 0;
    const rate_f = @as(f64, @floatFromInt(sample_rate));
    const two_pi = 2.0 * std.math.pi;

    for (notes) |n| {
        const frames = msToFrames(sample_rate, beatToMs(bpm, n.beats));
        if (n.freq_hz == Rest) {
            @memset(out[write_idx .. write_idx + frames], 0);
            write_idx += frames;
            continue;
        }
        var phase: f64 = 0.0;
        const step = two_pi * n.freq_hz / rate_f;
        for (0..frames) |i| {
            const s = std.math.sin(phase) * amp * 32767.0;
            out[write_idx + i] = @intFromFloat(std.math.clamp(s, -32768.0, 32767.0));
            phase += step;
            if (phase >= two_pi) phase -= two_pi;
        }
        write_idx += frames;
    }
    return out;
}
