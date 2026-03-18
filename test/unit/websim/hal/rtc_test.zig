const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const rtc = embed.websim.hal.rtc;

test "websim rtc satisfies hal contract" {
    const RtcReader = embed.hal.rtc.reader.from(struct {
        pub const Driver = rtc.Rtc;
        pub const meta = .{ .id = "rtc.websim" };
    });

    var drv = rtc.Rtc.init();
    var r = RtcReader.init(&drv);

    const up = r.uptime();
    try std.testing.expect(up < 1000);

    const ms = r.nowMs();
    try std.testing.expect(ms != null);
    try std.testing.expect(ms.? > 0);
    try std.testing.expect(r.isSynced());
}
