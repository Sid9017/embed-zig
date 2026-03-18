const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const hal = embed.hal;
const es8311 = embed.pkg.drivers.es8311;

// ============================================================================
// Tests
// ============================================================================

const MockI2c = struct {
    registers: [256]u8 = [_]u8{0} ** 256,

    pub fn writeRead(self: *MockI2c, _: u7, write_buf: []const u8, read_buf: []u8) hal.i2c.Error!void {
        if (write_buf.len > 0 and read_buf.len > 0) {
            const reg = write_buf[0];
            read_buf[0] = self.registers[reg];
        }
    }

    pub fn write(self: *MockI2c, _: u7, buf: []const u8) hal.i2c.Error!void {
        if (buf.len >= 2) {
            const reg = buf[0];
            self.registers[reg] = buf[1];
        }
    }
};

const MockI2cSpec = struct {
    pub const Driver = MockI2c;
    pub const meta = .{ .id = "i2c.mock-es8311" };
};

test "Es8311 basic operations" {
    var mock = MockI2c{};
    var codec = es8311.Es8311(MockI2cSpec).init(&mock, .{ .address = @intFromEnum(es8311.Address.ad0_low) });

    try codec.open();
    try std.testing.expect(codec.is_open);

    try codec.setMicGain(.@"24dB");
    try std.testing.expectEqual(@as(u8, 4), mock.registers[@intFromEnum(es8311.Register.adc_16)]);

    try codec.setVolume(128);
    try std.testing.expectEqual(@as(u8, 128), mock.registers[@intFromEnum(es8311.Register.dac_32)]);
}

test "MicGain fromDb" {
    try std.testing.expectEqual(es8311.MicGain.@"0dB", es8311.MicGain.fromDb(0));
    try std.testing.expectEqual(es8311.MicGain.@"6dB", es8311.MicGain.fromDb(6));
    try std.testing.expectEqual(es8311.MicGain.@"24dB", es8311.MicGain.fromDb(24));
    try std.testing.expectEqual(es8311.MicGain.@"42dB", es8311.MicGain.fromDb(50));
}
