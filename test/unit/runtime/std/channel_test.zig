const std = @import("std");
const embed = @import("embed");
const channel_factory = embed.runtime.std.ChannelFactory;
const runner = embed.runtime.test_runners.channel;

const StdChannel = channel_factory.Channel(u32);
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
