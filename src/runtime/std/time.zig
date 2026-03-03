const std = @import("std");

pub const StdTime = struct {
    pub fn nowMs() u64 {
        const ts = std.time.milliTimestamp();
        return if (ts <= 0) 0 else @intCast(ts);
    }

    pub fn sleepMs(ms: u32) void {
        std.Thread.sleep(@as(u64, ms) * std.time.ns_per_ms);
    }
};
