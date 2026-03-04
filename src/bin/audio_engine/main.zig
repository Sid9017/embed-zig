const std = @import("std");
const songs = @import("songs.zig");
const play = @import("play.zig");
const aec = @import("aec.zig");

fn parseSampleRate(raw: []const u8) !u32 {
    if (std.mem.eql(u8, raw, "16k") or std.mem.eql(u8, raw, "16000")) return 16_000;
    if (std.mem.eql(u8, raw, "24k") or std.mem.eql(u8, raw, "24000")) return 24_000;
    if (std.mem.eql(u8, raw, "48k") or std.mem.eql(u8, raw, "48000")) return 48_000;
    return error.UnsupportedFormat;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var song_id: []const u8 = "twinkle_star";
    var sample_rate: u32 = 16_000;
    var src_sample_rate: ?u32 = null;
    var command: enum { play_cmd, aec_cmd } = .play_cmd;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "play")) {
            command = .play_cmd;
            continue;
        }
        if (std.mem.eql(u8, arg, "aec")) {
            command = .aec_cmd;
            continue;
        }
        if (std.mem.eql(u8, arg, "--list")) {
            songs.printList();
            return;
        }
        if (std.mem.eql(u8, arg, "--song")) {
            song_id = args.next() orelse return error.MissingSongId;
            continue;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            const raw = args.next() orelse return error.MissingFormat;
            sample_rate = try parseSampleRate(raw);
            continue;
        }
        if (std.mem.eql(u8, arg, "--source-format")) {
            const raw = args.next() orelse return error.MissingSourceFormat;
            src_sample_rate = try parseSampleRate(raw);
            continue;
        }
    }

    switch (command) {
        .play_cmd => try play.run(allocator, .{
            .song_id = song_id,
            .sample_rate = sample_rate,
            .src_sample_rate = src_sample_rate orelse sample_rate,
        }),
        .aec_cmd => try aec.run(allocator, .{
            .song_id = song_id,
            .sample_rate = sample_rate,
        }),
    }
}
