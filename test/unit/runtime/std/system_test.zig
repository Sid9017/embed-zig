const std = @import("std");
const embed = @import("embed");
const Std = embed.runtime.std;

const std_system: Std.System = .{};

test "std system getCpuCount" {
    const cpu = try std_system.getCpuCount();
    try std.testing.expect(cpu >= 1);
}
