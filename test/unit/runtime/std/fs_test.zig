const std = @import("std");
const embed = @import("embed");
const Std = embed.runtime.std;
const Time = Std.Time;
const Fs = Std.Fs;

const std_time: Time = .{};
var unique_counter = std.atomic.Value(u64).init(0);

fn makeTmpPath(comptime tag: []const u8, comptime suffix: []const u8, buf: []u8) []const u8 {
    const id = unique_counter.fetchAdd(1, .seq_cst);
    return std.fmt.bufPrint(buf, "/tmp/embed_zig_runtime_{s}_{d}_{d}{s}", .{ tag, std_time.nowMs(), id, suffix }) catch unreachable;
}

test "std fs read/write roundtrip" {
    var fs_impl = Fs.init();

    var path_buf: [256]u8 = undefined;
    const path = makeTmpPath("fs", ".bin", &path_buf);
    defer std.fs.deleteFileAbsolute(path) catch {};

    var out = fs_impl.open(path, .write) orelse return error.TestUnexpectedResult;
    defer out.close();
    const wrote = try out.write("hello-std-runtime");
    try std.testing.expectEqual(@as(usize, "hello-std-runtime".len), wrote);

    var in = fs_impl.open(path, .read) orelse return error.TestUnexpectedResult;
    defer in.close();
    var buf: [64]u8 = undefined;
    const got = try in.readAll(&buf);
    try std.testing.expectEqualStrings("hello-std-runtime", got);
}
