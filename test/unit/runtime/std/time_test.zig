const std = @import("std");
const embed = @import("embed");
const Std = embed.runtime.std;

const std_time: Std.Time = .{};

test "std time nowMs returns positive value" {
    const now = std_time.nowMs();
    try std.testing.expect(now > 0);
}
