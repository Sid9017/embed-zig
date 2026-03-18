const std = @import("std");
const testing = std.testing;
const embed = @import("embed");

const mic_mod = embed.hal.mic;

test "mic wrapper" {
    const MockDriver = struct {
        sample_value: i16 = 1234,

        pub fn read(self: *@This(), buffer: []i16) mic_mod.Error!usize {
            for (buffer) |*s| s.* = self.sample_value;
            return buffer.len;
        }

        pub fn setGain(_: *@This(), _: i8) mic_mod.Error!void {}
        pub fn start(_: *@This()) mic_mod.Error!void {}
        pub fn stop(_: *@This()) mic_mod.Error!void {}
    };

    const Mic = mic_mod.from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "mic.test" };
        pub const config = mic_mod.Config{ .sample_rate = 16000 };
    });

    var d = MockDriver{};
    var mic = Mic.init(&d);

    var buffer: [16]i16 = undefined;
    const n = try mic.read(&buffer);
    try std.testing.expectEqual(@as(usize, 16), n);
    try std.testing.expectEqual(@as(i16, 1234), buffer[0]);
    try std.testing.expect(Mic.supportsGain());
    try std.testing.expectEqual(@as(u32, 160), Mic.samplesForMs(10));
}
