const std = @import("std");

pub const StdLog = struct {
    pub fn debug(msg: []const u8) void {
        std.debug.print("[debug] {s}\n", .{msg});
    }

    pub fn info(msg: []const u8) void {
        std.debug.print("[info] {s}\n", .{msg});
    }

    pub fn warn(msg: []const u8) void {
        std.debug.print("[warn] {s}\n", .{msg});
    }

    pub fn err(msg: []const u8) void {
        std.debug.print("[error] {s}\n", .{msg});
    }
};
