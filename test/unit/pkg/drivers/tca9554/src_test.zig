const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const tca9554 = embed.pkg.drivers.tca9554;

// ============================================================================
// Tests
// ============================================================================

const MockI2c = struct {
    registers: [4]u8 = .{ 0xFF, 0xFF, 0x00, 0xFF },
    last_write_addr: ?u8 = null,
    last_write_data: ?u8 = null,

    pub fn writeRead(self: *MockI2c, _: u7, write_buf: []const u8, read_buf: []u8) !void {
        if (write_buf.len > 0 and read_buf.len > 0) {
            const reg = write_buf[0];
            if (reg < 4) {
                read_buf[0] = self.registers[reg];
            }
        }
    }

    pub fn write(self: *MockI2c, _: u7, buf: []const u8) !void {
        if (buf.len >= 2) {
            const reg = buf[0];
            if (reg < 4) {
                self.registers[reg] = buf[1];
                self.last_write_addr = reg;
                self.last_write_data = buf[1];
            }
        }
    }
};

test "Tca9554 basic operations" {
    var mock = MockI2c{};
    var gpio = tca9554.Tca9554(*MockI2c).init(&mock, 0x20);

    try gpio.setDirection(.pin6, .output);
    try std.testing.expectEqual(@as(u8, 0xBF), mock.registers[@intFromEnum(tca9554.Register.config)]);

    try gpio.write(.pin6, .high);
    try std.testing.expectEqual(@as(u8, 0xFF), mock.registers[@intFromEnum(tca9554.Register.output)]);

    try gpio.write(.pin6, .low);
    try std.testing.expectEqual(@as(u8, 0xBF), mock.registers[@intFromEnum(tca9554.Register.output)]);
}

test "Tca9554 configure output" {
    var mock = MockI2c{};
    var gpio = tca9554.Tca9554(*MockI2c).init(&mock, 0x20);

    try gpio.configureOutput(.pin7, .low);
    try std.testing.expectEqual(@as(u8, 0x7F), mock.registers[@intFromEnum(tca9554.Register.output)]);
    try std.testing.expectEqual(@as(u8, 0x7F), mock.registers[@intFromEnum(tca9554.Register.config)]);
}

test "Pin mask" {
    try std.testing.expectEqual(@as(u8, 0x01), tca9554.Pin.pin0.mask());
    try std.testing.expectEqual(@as(u8, 0x40), tca9554.Pin.pin6.mask());
    try std.testing.expectEqual(@as(u8, 0x80), tca9554.Pin.pin7.mask());
}
