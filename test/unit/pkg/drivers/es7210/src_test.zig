const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const es7210 = embed.pkg.drivers.es7210;

// ============================================================================
// Tests
// ============================================================================

const MockI2c = struct {
    registers: [256]u8 = [_]u8{0} ** 256,

    pub fn writeRead(self: *MockI2c, _: u7, write_buf: []const u8, read_buf: []u8) !void {
        if (write_buf.len > 0 and read_buf.len > 0) {
            const reg = write_buf[0];
            read_buf[0] = self.registers[reg];
        }
    }

    pub fn write(self: *MockI2c, _: u7, buf: []const u8) !void {
        if (buf.len >= 2) {
            const reg = buf[0];
            self.registers[reg] = buf[1];
        }
    }
};

const MockI2cSpec = struct {
    pub const Driver = MockI2c;
    pub const meta = .{ .id = "test.i2c" };
};

test "Es7210 basic operations" {
    var mock = MockI2c{};
    var adc = es7210.Es7210(MockI2cSpec).init(&mock, .{
        .mic_select = .{ .mic1 = true, .mic2 = true, .mic3 = true },
    });

    // Test open
    try adc.open();
    try std.testing.expect(adc.is_open);

    // Test TDM mode (3 mics)
    try std.testing.expect(adc.isTdmMode());

    // Test set gain
    try adc.setGainAll(.@"24dB");
    try std.testing.expectEqual(es7210.Gain.@"24dB", adc.gain);
}

test "MicSelect operations" {
    const mics = es7210.MicSelect{ .mic1 = true, .mic2 = true, .mic3 = false, .mic4 = false };
    try std.testing.expectEqual(@as(u8, 2), mics.count());
    try std.testing.expectEqual(@as(u8, 0b0011), mics.toU8());
}

test "Gain fromDb" {
    try std.testing.expectEqual(es7210.Gain.@"0dB", es7210.Gain.fromDb(0));
    try std.testing.expectEqual(es7210.Gain.@"30dB", es7210.Gain.fromDb(30));
    try std.testing.expectEqual(es7210.Gain.@"37.5dB", es7210.Gain.fromDb(40));
}
