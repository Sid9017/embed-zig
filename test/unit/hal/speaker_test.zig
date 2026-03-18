const std = @import("std");
const testing = std.testing;
const embed = @import("embed");

const speaker = embed.hal.speaker;

test "speaker wrapper" {
    const MockDriver = struct {
        wrote: usize = 0,
        vol: u8 = 0,
        mute: bool = false,

        pub fn write(self: *@This(), buffer: []const i16) speaker.Error!usize {
            self.wrote += buffer.len;
            return buffer.len;
        }

        pub fn setVolume(self: *@This(), volume: u8) speaker.Error!void {
            self.vol = volume;
        }

        pub fn setMute(self: *@This(), muted: bool) speaker.Error!void {
            self.mute = muted;
        }
    };

    const Speaker = speaker.from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "speaker.test" };
    });

    var d = MockDriver{};
    var spk = Speaker.init(&d);

    _ = try spk.write(&[_]i16{ 1, 2, 3, 4 });
    try std.testing.expectEqual(@as(usize, 4), d.wrote);

    try spk.setVolume(200);
    try spk.setMute(true);
    try std.testing.expectEqual(@as(u8, 200), d.vol);
    try std.testing.expect(d.mute);
}
