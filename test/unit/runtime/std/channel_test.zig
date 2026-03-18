const std = @import("std");
const embed = @import("embed");
const ChannelTestRunner = embed.runtime.test_runners.ChannelTestRunner;

const TestRunner = ChannelTestRunner(embed.runtime.std.ChannelFactory);

test "std channel passes basic tests" {
    try TestRunner.run(std.testing.allocator, .{ .basic = true });
}

test "std channel passes concurrency tests" {
    try TestRunner.run(std.testing.allocator, .{ .concurrency = true });
}

test "std channel passes unbuffered tests" {
    try TestRunner.run(std.testing.allocator, .{ .unbuffered = true });
}
