const std = @import("std");
const embed = @import("../../mod.zig");

pub const Rtc = struct {
    start_ms: i64,

    pub fn init() Rtc {
        return .{ .start_ms = std.time.milliTimestamp() };
    }

    pub fn deinit(_: *Rtc) void {}

    pub fn uptime(self: *Rtc) u64 {
        const now = std.time.milliTimestamp();
        return @intCast(now - self.start_ms);
    }

    pub fn nowMs(_: *Rtc) ?i64 {
        return std.time.milliTimestamp();
    }
};
