//! TCA9554 / TCA9554A I2C GPIO Expander Driver
//!
//! Platform-independent driver for Texas Instruments TCA9554/TCA9554A
//! 8-bit I2C I/O expander with interrupt output.
//!
//! Features:
//! - 8 GPIO pins (directly addressable or as bitmask)
//! - Configurable as input or output
//! - Polarity inversion for inputs
//! - Optional interrupt on input change
//!
//! Usage:
//!   const Tca9554 = drivers.Tca9554(MyI2cBus);
//!   var gpio = Tca9554.init(i2c_bus, 0x20);
//!   try gpio.setDirection(.pin6, .output);
//!   try gpio.write(.pin6, .high);

const std = @import("std");

/// TCA9554 register addresses
pub const Register = enum(u8) {
    input = 0x00,
    output = 0x01,
    polarity = 0x02,
    config = 0x03,
};

// ============================================================================
// Register Bit Field Constants
// ============================================================================

/// Default register values after power-on reset
pub const Defaults = struct {
    pub const INPUT: u8 = 0xFF;
    pub const OUTPUT: u8 = 0xFF;
    pub const POLARITY: u8 = 0x00;
    pub const CONFIG: u8 = 0xFF;
};

/// Common I2C addresses
pub const Address = struct {
    pub const TCA9554_BASE: u7 = 0x20;
    pub const TCA9554A_BASE: u7 = 0x38;
};

/// Pin masks for common use cases
pub const PinMask = struct {
    pub const NONE: u8 = 0x00;
    pub const ALL: u8 = 0xFF;
    pub const LOW_NIBBLE: u8 = 0x0F;
    pub const HIGH_NIBBLE: u8 = 0xF0;
};

/// GPIO pin identifiers
pub const Pin = enum(u3) {
    pin0 = 0,
    pin1 = 1,
    pin2 = 2,
    pin3 = 3,
    pin4 = 4,
    pin5 = 5,
    pin6 = 6,
    pin7 = 7,

    pub fn mask(self: Pin) u8 {
        return @as(u8, 1) << @intFromEnum(self);
    }
};

/// Pin direction
pub const Direction = enum(u1) {
    output = 0,
    input = 1,
};

/// Pin level
pub const Level = enum(u1) {
    low = 0,
    high = 1,
};

// ============================================================================
// Driver Implementation
// ============================================================================

/// TCA9554 GPIO Expander Driver.
/// Generic over I2C bus type for platform independence.
/// `I2cBus` must provide `write(addr, data) !void` and `writeRead(addr, data, out) !void`.
pub fn Tca9554(comptime I2cBus: type) type {
    return struct {
        const Self = @This();

        i2c: I2cBus,
        address: u7,

        output_cache: u8 = 0xFF,
        config_cache: u8 = 0xFF,

        pub fn init(i2c: I2cBus, address: u7) Self {
            return .{
                .i2c = i2c,
                .address = address,
            };
        }

        pub fn readRegister(self: *Self, reg: Register) !u8 {
            var buf: [1]u8 = undefined;
            try self.i2c.writeRead(self.address, &.{@intFromEnum(reg)}, &buf);
            return buf[0];
        }

        pub fn writeRegister(self: *Self, reg: Register, value: u8) !void {
            try self.i2c.write(self.address, &.{ @intFromEnum(reg), value });
        }

        // ====================================================================
        // High-level API
        // ====================================================================

        pub fn setDirection(self: *Self, pin: Pin, dir: Direction) !void {
            const m = pin.mask();
            if (dir == .output) {
                self.config_cache &= ~m;
            } else {
                self.config_cache |= m;
            }
            try self.writeRegister(.config, self.config_cache);
        }

        pub fn setDirectionMask(self: *Self, output_mask: u8) !void {
            self.config_cache = ~output_mask;
            try self.writeRegister(.config, self.config_cache);
        }

        pub fn write(self: *Self, pin: Pin, level: Level) !void {
            const m = pin.mask();
            if (level == .high) {
                self.output_cache |= m;
            } else {
                self.output_cache &= ~m;
            }
            try self.writeRegister(.output, self.output_cache);
        }

        pub fn writeMask(self: *Self, m: u8, levels: u8) !void {
            self.output_cache = (self.output_cache & ~m) | (levels & m);
            try self.writeRegister(.output, self.output_cache);
        }

        pub fn writeAll(self: *Self, value: u8) !void {
            self.output_cache = value;
            try self.writeRegister(.output, value);
        }

        pub fn read(self: *Self, pin: Pin) !Level {
            const value = try self.readRegister(.input);
            return if ((value & pin.mask()) != 0) .high else .low;
        }

        pub fn readAll(self: *Self) !u8 {
            return try self.readRegister(.input);
        }

        pub fn toggle(self: *Self, pin: Pin) !void {
            self.output_cache ^= pin.mask();
            try self.writeRegister(.output, self.output_cache);
        }

        pub fn setPolarity(self: *Self, pin: Pin, inverted: bool) !void {
            var polarity = try self.readRegister(.polarity);
            const m = pin.mask();
            if (inverted) {
                polarity |= m;
            } else {
                polarity &= ~m;
            }
            try self.writeRegister(.polarity, polarity);
        }

        // ====================================================================
        // Convenience functions
        // ====================================================================

        pub fn configureOutput(self: *Self, pin: Pin, initial: Level) !void {
            try self.write(pin, initial);
            try self.setDirection(pin, .output);
        }

        pub fn configureInput(self: *Self, pin: Pin) !void {
            try self.setDirection(pin, .input);
        }

        pub fn reset(self: *Self) !void {
            self.output_cache = Defaults.OUTPUT;
            self.config_cache = Defaults.CONFIG;
            try self.writeRegister(.output, Defaults.OUTPUT);
            try self.writeRegister(.polarity, Defaults.POLARITY);
            try self.writeRegister(.config, Defaults.CONFIG);
        }

        pub fn syncFromDevice(self: *Self) !void {
            self.config_cache = try self.readRegister(.config);
            self.output_cache = try self.readRegister(.output);
        }

        pub fn getDirection(self: *Self, pin: Pin) Direction {
            const m = pin.mask();
            return if ((self.config_cache & m) != 0) .input else .output;
        }

        pub fn getOutput(self: *Self, pin: Pin) Level {
            const m = pin.mask();
            return if ((self.output_cache & m) != 0) .high else .low;
        }

        pub fn getOutputAll(self: *Self) u8 {
            return self.output_cache;
        }

        pub fn getConfigAll(self: *Self) u8 {
            return self.config_cache;
        }

        pub fn isOutput(self: *Self, pin: Pin) bool {
            return self.getDirection(pin) == .output;
        }

        pub fn isInput(self: *Self, pin: Pin) bool {
            return self.getDirection(pin) == .input;
        }

        pub fn setAllOutputs(self: *Self) !void {
            self.config_cache = PinMask.NONE;
            try self.writeRegister(.config, self.config_cache);
        }

        pub fn setAllInputs(self: *Self) !void {
            self.config_cache = PinMask.ALL;
            try self.writeRegister(.config, self.config_cache);
        }

        pub fn setAllHigh(self: *Self) !void {
            self.output_cache = PinMask.ALL;
            try self.writeRegister(.output, self.output_cache);
        }

        pub fn setAllLow(self: *Self) !void {
            self.output_cache = PinMask.NONE;
            try self.writeRegister(.output, self.output_cache);
        }

        pub fn setPolarityMask(self: *Self, invert_mask: u8) !void {
            try self.writeRegister(.polarity, invert_mask);
        }

        pub fn getPolarity(self: *Self) !u8 {
            return try self.readRegister(.polarity);
        }

        pub fn configureMultiple(self: *Self, output_pins: u8, initial_levels: u8) !void {
            self.output_cache = initial_levels;
            self.config_cache = ~output_pins;
            try self.writeRegister(.output, self.output_cache);
            try self.writeRegister(.config, self.config_cache);
        }

        pub fn pulse(self: *Self, pin: Pin) !void {
            try self.toggle(pin);
            try self.toggle(pin);
        }

        pub fn setHigh(self: *Self, pin: Pin) !void {
            try self.write(pin, .high);
        }

        pub fn setLow(self: *Self, pin: Pin) !void {
            try self.write(pin, .low);
        }

        pub fn isHigh(self: *Self, pin: Pin) !bool {
            return (try self.read(pin)) == .high;
        }

        pub fn isLow(self: *Self, pin: Pin) !bool {
            return (try self.read(pin)) == .low;
        }
    };
}

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
    var gpio = Tca9554(*MockI2c).init(&mock, 0x20);

    try gpio.setDirection(.pin6, .output);
    try std.testing.expectEqual(@as(u8, 0xBF), mock.registers[@intFromEnum(Register.config)]);

    try gpio.write(.pin6, .high);
    try std.testing.expectEqual(@as(u8, 0xFF), mock.registers[@intFromEnum(Register.output)]);

    try gpio.write(.pin6, .low);
    try std.testing.expectEqual(@as(u8, 0xBF), mock.registers[@intFromEnum(Register.output)]);
}

test "Tca9554 configure output" {
    var mock = MockI2c{};
    var gpio = Tca9554(*MockI2c).init(&mock, 0x20);

    try gpio.configureOutput(.pin7, .low);
    try std.testing.expectEqual(@as(u8, 0x7F), mock.registers[@intFromEnum(Register.output)]);
    try std.testing.expectEqual(@as(u8, 0x7F), mock.registers[@intFromEnum(Register.config)]);
}

test "Pin mask" {
    try std.testing.expectEqual(@as(u8, 0x01), Pin.pin0.mask());
    try std.testing.expectEqual(@as(u8, 0x40), Pin.pin6.mask());
    try std.testing.expectEqual(@as(u8, 0x80), Pin.pin7.mask());
}
