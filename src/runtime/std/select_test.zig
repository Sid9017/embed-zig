const std = @import("std");
const channel = @import("channel.zig");
const sel = @import("select.zig");
const runner = @import("../select_test_runner.zig");

const StdChannel = channel.Channel(u32);
const StdSelector = sel.Selector(u32);
const TestRunner = runner.SelectTestRunner(StdSelector, StdChannel);

test "std select passes basic tests" {
    try TestRunner.run(std.testing.allocator, .{ .basic = true });
}

test "std select passes concurrency tests" {
    try TestRunner.run(std.testing.allocator, .{ .concurrency = true });
}
