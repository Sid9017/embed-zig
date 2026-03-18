const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const hal_display = embed.hal.display;
const websim_display = embed.websim.hal.display;
const websim = embed.websim;

test "websim display satisfies hal contract" {
    const router_mod = embed.websim.outbox;

    var running = std.atomic.Value(bool){ .raw = true };
    var router = router_mod.DevRouter.init(std.testing.allocator);
    defer router.deinit();
    var bus = websim.RemoteHal.initTest(&running, &router);
    const outbox = router.track("display");

    var drv = websim_display.Display{ .bus = &bus, .width_px = 8, .height_px = 4 };
    const DisplayHal = hal_display.from(struct {
        pub const Driver = websim_display.Display;
        pub const meta = .{ .id = "display.websim" };
    });

    var display = DisplayHal.init(&drv);
    const pixels = [_]hal_display.Color565{ 0x1111, 0x2222, 0x3333, 0x4444 };
    try display.drawBitmap(1, 1, 2, 2, &pixels);

    const state_msg = outbox.pop(10) orelse return error.ExpectedState;
    defer std.testing.allocator.free(state_msg);
    try std.testing.expect(std.mem.indexOf(u8, state_msg, "\"kind\":\"state\"") != null);

    const frame_msg = outbox.pop(10) orelse return error.ExpectedFrame;
    defer std.testing.allocator.free(frame_msg);
    try std.testing.expect(std.mem.indexOf(u8, frame_msg, "\"kind\":\"frame\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame_msg, "\"format\":\"rgb565le\"") != null);
}
