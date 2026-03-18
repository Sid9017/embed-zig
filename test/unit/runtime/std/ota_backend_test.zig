const std = @import("std");
const embed = @import("embed");
const Std = embed.runtime.std;
const Time = Std.Time;
const OtaBackend = Std.OtaBackend;

const std_time: Time = .{};
var unique_counter = std.atomic.Value(u64).init(0);

fn makeTmpPath(comptime tag: []const u8, comptime suffix: []const u8, buf: []u8) []const u8 {
    const id = unique_counter.fetchAdd(1, .seq_cst);
    return std.fmt.bufPrint(buf, "/tmp/embed_zig_runtime_{s}_{d}_{d}{s}", .{ tag, std_time.nowMs(), id, suffix }) catch unreachable;
}

test "std ota backend begin/write/finalize" {
    var stage_buf: [256]u8 = undefined;
    var final_buf: [256]u8 = undefined;
    var confirm_buf: [256]u8 = undefined;

    const stage_path = makeTmpPath("ota_stage", ".bin", &stage_buf);
    const final_path = makeTmpPath("ota_final", ".bin", &final_buf);
    const confirm_path = makeTmpPath("ota_confirm", "", &confirm_buf);
    defer std.fs.deleteFileAbsolute(stage_path) catch {};
    defer std.fs.deleteFileAbsolute(final_path) catch {};
    defer std.fs.deleteFileAbsolute(confirm_path) catch {};

    var ota = try OtaBackend.init();
    ota.impl.stage_path = stage_path;
    ota.impl.final_path = final_path;
    ota.impl.confirm_path = confirm_path;

    try std.testing.expectEqual(.unknown, ota.getState());

    try ota.begin(4);
    try ota.write("test");
    try ota.finalize();

    try std.testing.expectEqual(.pending_verify, ota.getState());

    try ota.confirm();
    try std.testing.expectEqual(.valid, ota.getState());

    var file = try std.fs.openFileAbsolute(final_path, .{ .mode = .read_only });
    defer file.close();
    var data: [8]u8 = undefined;
    const n = try file.read(&data);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("test", data[0..n]);
}

test "std ota backend rollback removes image" {
    var stage_buf: [256]u8 = undefined;
    var final_buf: [256]u8 = undefined;
    var confirm_buf: [256]u8 = undefined;

    const stage_path = makeTmpPath("ota_rb_stage", ".bin", &stage_buf);
    const final_path = makeTmpPath("ota_rb_final", ".bin", &final_buf);
    const confirm_path = makeTmpPath("ota_rb_confirm", "", &confirm_buf);
    defer std.fs.deleteFileAbsolute(stage_path) catch {};
    defer std.fs.deleteFileAbsolute(final_path) catch {};
    defer std.fs.deleteFileAbsolute(confirm_path) catch {};

    var ota = try OtaBackend.init();
    ota.impl.stage_path = stage_path;
    ota.impl.final_path = final_path;
    ota.impl.confirm_path = confirm_path;

    try ota.begin(3);
    try ota.write("bad");
    try ota.finalize();

    try std.testing.expectEqual(.pending_verify, ota.getState());

    try ota.rollback();
    try std.testing.expectEqual(.unknown, ota.getState());
}
