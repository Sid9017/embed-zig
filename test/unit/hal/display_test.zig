const std = @import("std");
const testing = std.testing;
const embed = @import("embed");

const Display = embed.hal.display;

// ============================================================================
// Tests
// ============================================================================

const Mock = struct {
    const W: u16 = 8;
    const H: u16 = 4;

    fb: [W * H]Display.Color565 = [_]Display.Color565{0} ** (W * H),
    enabled: bool = false,
    sleeping: bool = false,

    pub fn width(_: *const @This()) u16 {
        return W;
    }
    pub fn height(_: *const @This()) u16 {
        return H;
    }
    pub fn setDisplayEnabled(self: *@This(), enabled: bool) Display.Error!void {
        self.enabled = enabled;
    }
    pub fn sleep(self: *@This(), enabled: bool) Display.Error!void {
        self.sleeping = enabled;
    }
    pub fn drawBitmap(self: *@This(), x: u16, y: u16, w: u16, h: u16, data: []const Display.Color565) Display.Error!void {
        var row: u16 = 0;
        while (row < h) : (row += 1) {
            var col: u16 = 0;
            while (col < w) : (col += 1) {
                const dst = @as(usize, y + row) * W + @as(usize, x + col);
                const src = @as(usize, row) * w + @as(usize, col);
                self.fb[dst] = data[src];
            }
        }
    }
};

const TestDisplay = Display.from(struct {
    pub const Driver = Mock;
    pub const meta = .{ .id = "display.test" };
});

test "display enable and sleep" {
    var d = Mock{};
    var display = TestDisplay.init(&d);

    try display.setDisplayEnabled(true);
    try std.testing.expect(d.enabled);

    try display.setDisplayEnabled(false);
    try std.testing.expect(!d.enabled);

    try display.sleep(true);
    try std.testing.expect(d.sleeping);

    try display.sleep(false);
    try std.testing.expect(!d.sleeping);
}

test "drawBitmap partial region" {
    var d = Mock{};
    var display = TestDisplay.init(&d);

    const pixels = [_]Display.Color565{ 0x1111, 0x2222, 0x3333, 0x4444 };
    try display.drawBitmap(3, 1, 2, 2, &pixels);

    try std.testing.expectEqual(@as(Display.Color565, 0x1111), d.fb[1 * Mock.W + 3]);
    try std.testing.expectEqual(@as(Display.Color565, 0x2222), d.fb[1 * Mock.W + 4]);
    try std.testing.expectEqual(@as(Display.Color565, 0x3333), d.fb[2 * Mock.W + 3]);
    try std.testing.expectEqual(@as(Display.Color565, 0x4444), d.fb[2 * Mock.W + 4]);

    try std.testing.expectEqual(@as(Display.Color565, 0), d.fb[1 * Mock.W + 2]);
    try std.testing.expectEqual(@as(Display.Color565, 0), d.fb[1 * Mock.W + 5]);
    try std.testing.expectEqual(@as(Display.Color565, 0), d.fb[0 * Mock.W + 3]);
    try std.testing.expectEqual(@as(Display.Color565, 0), d.fb[3 * Mock.W + 3]);
}

test "drawBitmap zero size Display.is no-op" {
    var d = Mock{};
    var display = TestDisplay.init(&d);
    try display.drawBitmap(0, 0, 0, 0, &[_]Display.Color565{});
}

test "drawBitmap out of bounds" {
    var d = Mock{};
    var display = TestDisplay.init(&d);
    const pixels = [_]Display.Color565{ 0x1111, 0x2222, 0x3333, 0x4444 };
    try std.testing.expectError(error.OutOfBounds, display.drawBitmap(7, 3, 2, 2, &pixels));
}
