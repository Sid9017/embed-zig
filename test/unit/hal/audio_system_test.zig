const std = @import("std");
const testing = std.testing;
const embed = @import("embed");

const audio_system = embed.hal.audio_system;

test "audio_system wrapper" {
    const mic_count = 2;
    const FrameType = audio_system.Frame(mic_count);

    const MockDriver = struct {
        mic_buf: [mic_count][4]i16 = .{
            .{ 10, 20, 30, 40 },
            .{ 50, 60, 70, 80 },
        },
        ref_buf: [4]i16 = .{ 1, 2, 3, 4 },
        wrote: usize = 0,
        mic_gains: [mic_count]i8 = .{ 0, 0 },
        spk_gain: i8 = 0,

        pub fn init() !@This() {
            return .{};
        }

        pub fn deinit(_: *@This()) void {}

        pub fn readFrame(self: *@This()) audio_system.Error!FrameType {
            return .{
                .mic = .{ &self.mic_buf[0], &self.mic_buf[1] },
                .ref = &self.ref_buf,
            };
        }

        pub fn writeSpk(self: *@This(), buffer: []const i16) audio_system.Error!usize {
            self.wrote += buffer.len;
            return buffer.len;
        }

        pub fn setMicGain(self: *@This(), index: u8, gain_db: i8) audio_system.Error!void {
            if (index >= mic_count) return error.InvalidState;
            self.mic_gains[index] = gain_db;
        }

        pub fn setSpkGain(self: *@This(), gain_db: i8) audio_system.Error!void {
            self.spk_gain = gain_db;
        }

        pub fn start(_: *@This()) audio_system.Error!void {}
        pub fn stop(_: *@This()) audio_system.Error!void {}
    };

    const AudioSystem = audio_system.from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "audio_system.test" };
        pub const config = audio_system.Config{ .sample_rate = 16000, .mic_count = mic_count };
    });

    var d = try MockDriver.init();
    var sys = AudioSystem.init(&d);

    const frame = try sys.readFrame();
    try std.testing.expectEqual(@as(i16, 10), frame.mic[0][0]);
    try std.testing.expectEqual(@as(i16, 50), frame.mic[1][0]);
    try std.testing.expectEqual(@as(i16, 1), frame.ref[0]);

    _ = try sys.writeSpk(&[_]i16{ 100, 200 });
    try std.testing.expectEqual(@as(usize, 2), d.wrote);

    try sys.setMicGain(0, 12);
    try sys.setMicGain(1, -6);
    try std.testing.expectEqual(@as(i8, 12), d.mic_gains[0]);
    try std.testing.expectEqual(@as(i8, -6), d.mic_gains[1]);

    try sys.setSpkGain(3);
    try std.testing.expectEqual(@as(i8, 3), d.spk_gain);

    try std.testing.expect(audio_system.is(AudioSystem));
    try std.testing.expectEqual(@as(u32, 160), AudioSystem.samplesForMs(10));
    try std.testing.expectEqual(@as(u32, 10), AudioSystem.msForSamples(160));
}
