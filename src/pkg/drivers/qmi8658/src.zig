//! QMI8658 6-Axis IMU Driver
//!
//! Platform-independent driver for QST QMI8658 6-axis inertial measurement unit.
//! Integrates 3-axis accelerometer and 3-axis gyroscope.
//!
//! Features:
//! - Accelerometer: ±2g, ±4g, ±8g, ±16g full scale
//! - Gyroscope: ±16 to ±2048 dps full scale
//! - Configurable output data rate (ODR)
//! - Temperature sensor
//! - FIFO support
//!
//! Usage:
//!   const Qmi8658 = drivers.Qmi8658(MyI2cBus, MyTime);
//!   var imu = Qmi8658.init(i2c_bus, .{});
//!   try imu.open();
//!   const data = try imu.read();

const std = @import("std");
const qmi8658 = @This();

/// QMI8658 I2C addresses (depends on SA0 pin)
pub const Address = enum(u7) {
    sa0_low = 0x6A,
    sa0_high = 0x6B,
};

/// Expected WHO_AM_I value
pub const WHO_AM_I_VALUE: u8 = 0x05;

/// QMI8658 register addresses
pub const Register = enum(u8) {
    who_am_i = 0x00,
    revision_id = 0x01,
    ctrl1 = 0x02,
    ctrl2 = 0x03,
    ctrl3 = 0x04,
    ctrl4 = 0x05,
    ctrl5 = 0x06,
    ctrl6 = 0x07,
    ctrl7 = 0x08,
    ctrl8 = 0x09,
    ctrl9 = 0x0A,
    fifo_wtm_th = 0x13,
    fifo_ctrl = 0x14,
    fifo_smpl_cnt = 0x15,
    fifo_status = 0x16,
    fifo_data = 0x17,
    statusint = 0x2D,
    status0 = 0x2E,
    status1 = 0x2F,
    timestamp_low = 0x30,
    timestamp_mid = 0x31,
    timestamp_high = 0x32,
    temp_l = 0x33,
    temp_h = 0x34,
    ax_l = 0x35,
    ax_h = 0x36,
    ay_l = 0x37,
    ay_h = 0x38,
    az_l = 0x39,
    az_h = 0x3A,
    gx_l = 0x3B,
    gx_h = 0x3C,
    gy_l = 0x3D,
    gy_h = 0x3E,
    gz_l = 0x3F,
    gz_h = 0x40,
    cod_status = 0x46,
    dqw_l = 0x49,
    dqw_h = 0x4A,
    dqx_l = 0x4B,
    dqx_h = 0x4C,
    dqy_l = 0x4D,
    dqy_h = 0x4E,
    dqz_l = 0x4F,
    dqz_h = 0x50,
    dvx_l = 0x51,
    dvx_h = 0x52,
    dvy_l = 0x53,
    dvy_h = 0x54,
    dvz_l = 0x55,
    dvz_h = 0x56,
    tap_status = 0x59,
    step_cnt_low = 0x5A,
    step_cnt_mid = 0x5B,
    step_cnt_high = 0x5C,
    reset = 0x60,
};

// ============================================================================
// Configuration Enums
// ============================================================================

/// Accelerometer full scale range
pub const AccelRange = enum(u3) {
    @"2g" = 0b000,
    @"4g" = 0b001,
    @"8g" = 0b010,
    @"16g" = 0b011,

    pub fn sensitivity(self: AccelRange) f32 {
        return switch (self) {
            .@"2g" => 16384.0,
            .@"4g" => 8192.0,
            .@"8g" => 4096.0,
            .@"16g" => 2048.0,
        };
    }
};

/// Gyroscope full scale range
pub const GyroRange = enum(u3) {
    @"16dps" = 0b000,
    @"32dps" = 0b001,
    @"64dps" = 0b010,
    @"128dps" = 0b011,
    @"256dps" = 0b100,
    @"512dps" = 0b101,
    @"1024dps" = 0b110,
    @"2048dps" = 0b111,

    pub fn sensitivity(self: GyroRange) f32 {
        return switch (self) {
            .@"16dps" => 2048.0,
            .@"32dps" => 1024.0,
            .@"64dps" => 512.0,
            .@"128dps" => 256.0,
            .@"256dps" => 128.0,
            .@"512dps" => 64.0,
            .@"1024dps" => 32.0,
            .@"2048dps" => 16.0,
        };
    }
};

/// Output data rate for accelerometer
pub const AccelOdr = enum(u4) {
    @"8000Hz" = 0b0000,
    @"4000Hz" = 0b0001,
    @"2000Hz" = 0b0010,
    @"1000Hz" = 0b0011,
    @"500Hz" = 0b0100,
    @"250Hz" = 0b0101,
    @"125Hz" = 0b0110,
    @"62.5Hz" = 0b0111,
    @"31.25Hz" = 0b1000,
    low_power_128Hz = 0b1100,
    low_power_21Hz = 0b1101,
    low_power_11Hz = 0b1110,
    low_power_3Hz = 0b1111,
};

/// Output data rate for gyroscope
pub const GyroOdr = enum(u4) {
    @"8000Hz" = 0b0000,
    @"4000Hz" = 0b0001,
    @"2000Hz" = 0b0010,
    @"1000Hz" = 0b0011,
    @"500Hz" = 0b0100,
    @"250Hz" = 0b0101,
    @"125Hz" = 0b0110,
    @"62.5Hz" = 0b0111,
    @"31.25Hz" = 0b1000,
};

// ============================================================================
// Data Structures
// ============================================================================

/// Raw IMU data (16-bit signed values)
pub const RawData = struct {
    acc_x: i16 = 0,
    acc_y: i16 = 0,
    acc_z: i16 = 0,
    gyr_x: i16 = 0,
    gyr_y: i16 = 0,
    gyr_z: i16 = 0,
};

/// Scaled IMU data (physical units)
pub const ScaledData = struct {
    acc_x: f32 = 0,
    acc_y: f32 = 0,
    acc_z: f32 = 0,
    gyr_x: f32 = 0,
    gyr_y: f32 = 0,
    gyr_z: f32 = 0,
};

/// Euler angles calculated from accelerometer.
/// Yaw cannot be determined from accelerometer alone.
pub const Angles = struct {
    roll: f32 = 0,
    pitch: f32 = 0,
};

/// Configuration for QMI8658
pub const Config = struct {
    address: u7,
    accel_range: AccelRange = .@"4g",
    gyro_range: GyroRange = .@"512dps",
    accel_odr: AccelOdr = .@"250Hz",
    gyro_odr: GyroOdr = .@"250Hz",
};

// ============================================================================
// Driver Implementation
// ============================================================================

/// QMI8658 6-Axis IMU Driver.
/// Generic over I2C bus type and Time interface for platform independence.
/// `I2cBus` must provide `write(addr, data) !void` and `writeRead(addr, data, out) !void`.
/// `TimeImpl` must provide `sleepMs(ms) void`.
pub fn Qmi8658(comptime I2cBus: type, comptime TimeImpl: type) type {
    return struct {
        const Self = @This();

        pub const capabilities = struct {
            pub const has_gyro = true;
            pub const has_temp = true;
            pub const axis_count = 6;
        };

        i2c: I2cBus,
        config: Config,
        is_open: bool = false,

        pub fn init(i2c: I2cBus, config: Config) Self {
            return .{
                .i2c = i2c,
                .config = config,
            };
        }

        pub fn readRegister(self: *Self, reg: Register) !u8 {
            var buf: [1]u8 = undefined;
            try self.i2c.writeRead(self.config.address, &.{@intFromEnum(reg)}, &buf);
            return buf[0];
        }

        pub fn writeRegister(self: *Self, reg: Register, value: u8) !void {
            try self.i2c.write(self.config.address, &.{ @intFromEnum(reg), value });
        }

        pub fn readRegisters(self: *Self, start_reg: Register, buf: []u8) !void {
            try self.i2c.writeRead(self.config.address, &.{@intFromEnum(start_reg)}, buf);
        }

        // ====================================================================
        // High-level API
        // ====================================================================

        pub fn open(self: *Self) !void {
            const id = try self.readRegister(.who_am_i);
            if (id != WHO_AM_I_VALUE) {
                return error.InvalidChipId;
            }

            try self.writeRegister(.reset, 0xB0);

            TimeImpl.sleepMs(10);

            try self.writeRegister(.ctrl1, 0x40);
            try self.writeRegister(.ctrl7, 0x03);

            const ctrl2 = (@as(u8, @intFromEnum(self.config.accel_range)) << 4) |
                @as(u8, @intFromEnum(self.config.accel_odr));
            try self.writeRegister(.ctrl2, ctrl2);

            const ctrl3 = (@as(u8, @intFromEnum(self.config.gyro_range)) << 4) |
                @as(u8, @intFromEnum(self.config.gyro_odr));
            try self.writeRegister(.ctrl3, ctrl3);

            self.is_open = true;
        }

        pub fn close(self: *Self) !void {
            if (self.is_open) {
                try self.writeRegister(.ctrl7, 0x00);
                self.is_open = false;
            }
        }

        pub fn isDataReady(self: *Self) !bool {
            const status = try self.readRegister(.status0);
            return (status & 0x03) == 0x03;
        }

        pub fn readRaw(self: *Self) !qmi8658.RawData {
            if (!self.is_open) return error.NotOpen;

            var buf: [12]u8 = undefined;
            try self.readRegisters(.ax_l, &buf);

            return qmi8658.RawData{
                .acc_x = @bitCast([2]u8{ buf[0], buf[1] }),
                .acc_y = @bitCast([2]u8{ buf[2], buf[3] }),
                .acc_z = @bitCast([2]u8{ buf[4], buf[5] }),
                .gyr_x = @bitCast([2]u8{ buf[6], buf[7] }),
                .gyr_y = @bitCast([2]u8{ buf[8], buf[9] }),
                .gyr_z = @bitCast([2]u8{ buf[10], buf[11] }),
            };
        }

        pub fn readScaled(self: *Self) !qmi8658.ScaledData {
            const raw = try self.readRaw();
            const acc_sens = self.config.accel_range.sensitivity();
            const gyr_sens = self.config.gyro_range.sensitivity();

            return qmi8658.ScaledData{
                .acc_x = @as(f32, @floatFromInt(raw.acc_x)) / acc_sens,
                .acc_y = @as(f32, @floatFromInt(raw.acc_y)) / acc_sens,
                .acc_z = @as(f32, @floatFromInt(raw.acc_z)) / acc_sens,
                .gyr_x = @as(f32, @floatFromInt(raw.gyr_x)) / gyr_sens,
                .gyr_y = @as(f32, @floatFromInt(raw.gyr_y)) / gyr_sens,
                .gyr_z = @as(f32, @floatFromInt(raw.gyr_z)) / gyr_sens,
            };
        }

        /// Calculate tilt angles from accelerometer data.
        /// Only accurate when the device is stationary or moving slowly.
        pub fn readAngles(self: *Self) !qmi8658.Angles {
            const raw = try self.readRaw();
            const ax: f32 = @floatFromInt(raw.acc_x);
            const ay: f32 = @floatFromInt(raw.acc_y);
            const az: f32 = @floatFromInt(raw.acc_z);

            const roll = std.math.atan2(ay, az) * (180.0 / std.math.pi);
            const pitch = std.math.atan2(-ax, @sqrt(ay * ay + az * az)) * (180.0 / std.math.pi);

            return qmi8658.Angles{
                .roll = roll,
                .pitch = pitch,
            };
        }

        pub fn readTemperature(self: *Self) !f32 {
            if (!self.is_open) return error.NotOpen;

            var buf: [2]u8 = undefined;
            try self.readRegisters(.temp_l, &buf);
            const raw: i16 = @bitCast([2]u8{ buf[0], buf[1] });

            return @as(f32, @floatFromInt(raw)) / 256.0 + 25.0;
        }

        pub fn setAccelRange(self: *Self, range: qmi8658.AccelRange) !void {
            self.config.accel_range = range;
            if (self.is_open) {
                const ctrl2 = (@as(u8, @intFromEnum(range)) << 4) |
                    @as(u8, @intFromEnum(self.config.accel_odr));
                try self.writeRegister(.ctrl2, ctrl2);
            }
        }

        pub fn setGyroRange(self: *Self, range: qmi8658.GyroRange) !void {
            self.config.gyro_range = range;
            if (self.is_open) {
                const ctrl3 = (@as(u8, @intFromEnum(range)) << 4) |
                    @as(u8, @intFromEnum(self.config.gyro_odr));
                try self.writeRegister(.ctrl3, ctrl3);
            }
        }

        pub fn selfTest(self: *Self) !bool {
            const id = try self.readRegister(.who_am_i);
            return id == WHO_AM_I_VALUE;
        }

        pub fn getRevisionId(self: *Self) !u8 {
            return self.readRegister(.revision_id);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const MockTime = struct {
    pub fn sleepMs(_: u32) void {}
};

const MockI2c = struct {
    registers: [256]u8 = [_]u8{0} ** 256,

    pub fn init() MockI2c {
        var self = MockI2c{};
        self.registers[@intFromEnum(Register.who_am_i)] = WHO_AM_I_VALUE;
        return self;
    }

    pub fn writeRead(self: *MockI2c, _: u7, write_buf: []const u8, read_buf: []u8) !void {
        if (write_buf.len > 0) {
            const start_reg = write_buf[0];
            for (read_buf, 0..) |*byte, i| {
                byte.* = self.registers[start_reg + i];
            }
        }
    }

    pub fn write(self: *MockI2c, _: u7, buf: []const u8) !void {
        if (buf.len >= 2) {
            const reg = buf[0];
            self.registers[reg] = buf[1];
        }
    }
};

test "Qmi8658 initialization" {
    var mock = MockI2c.init();
    var imu = Qmi8658(*MockI2c, MockTime).init(&mock, .{});

    try imu.open();
    try std.testing.expect(imu.is_open);

    try imu.close();
    try std.testing.expect(!imu.is_open);
}

test "Qmi8658 self test" {
    var mock = MockI2c.init();
    var imu = Qmi8658(*MockI2c, MockTime).init(&mock, .{});

    const result = try imu.selfTest();
    try std.testing.expect(result);
}

test "AccelRange sensitivity" {
    try std.testing.expectEqual(@as(f32, 16384.0), AccelRange.@"2g".sensitivity());
    try std.testing.expectEqual(@as(f32, 8192.0), AccelRange.@"4g".sensitivity());
    try std.testing.expectEqual(@as(f32, 4096.0), AccelRange.@"8g".sensitivity());
    try std.testing.expectEqual(@as(f32, 2048.0), AccelRange.@"16g".sensitivity());
}

test "GyroRange sensitivity" {
    try std.testing.expectEqual(@as(f32, 64.0), GyroRange.@"512dps".sensitivity());
    try std.testing.expectEqual(@as(f32, 32.0), GyroRange.@"1024dps".sensitivity());
}
