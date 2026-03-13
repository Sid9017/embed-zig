const std = @import("std");
const channel = @import("channel.zig");
const runner = @import("../channel_test_runner.zig");

const StdChannel = channel.Channel(u32);
const TestRunner = runner.ChannelTestRunner(StdChannel);

test "std channel passes basic tests" {
    try TestRunner.run(std.testing.allocator, .{ .basic = true });
}

test "std channel passes concurrency tests" {
    try TestRunner.run(std.testing.allocator, .{ .concurrency = true });
}

test "std channel passes unbuffered tests" {
    try TestRunner.run(std.testing.allocator, .{ .unbuffered = true });
}
