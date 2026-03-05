# QMI8658 Register Map

QST QMI8658C — 6-Axis Inertial Measurement Unit (3-axis accelerometer + 3-axis gyroscope).
Datasheet: QMI8658C Revision 1.0.

I2C address: `110_10x0` (7-bit), where x = SA0 pin.
- SA0 = GND → 0x6A (default)
- SA0 = VDD → 0x6B

WHO_AM_I expected value: `0x05`.

## Register Summary

| Addr | Name | Driver Enum | Group |
|------|------|-------------|-------|
| 0x00 | WHO_AM_I | `who_am_i` | ID |
| 0x01 | REVISION_ID | `revision_id` | ID |
| 0x02 | CTRL1 | `ctrl1` | Control |
| 0x03 | CTRL2 | `ctrl2` | Accelerometer |
| 0x04 | CTRL3 | `ctrl3` | Gyroscope |
| 0x05 | CTRL4 | `ctrl4` | Reserved |
| 0x06 | CTRL5 | `ctrl5` | Low Power |
| 0x07 | CTRL6 | `ctrl6` | AttitudeEngine |
| 0x08 | CTRL7 | `ctrl7` | Sensor Enable |
| 0x09 | CTRL8 | `ctrl8` | Motion Detection |
| 0x0A | CTRL9 | `ctrl9` | Host Commands |
| 0x13 | FIFO_WTM_TH | `fifo_wtm_th` | FIFO |
| 0x14 | FIFO_CTRL | `fifo_ctrl` | FIFO |
| 0x15 | FIFO_SMPL_CNT | `fifo_smpl_cnt` | FIFO |
| 0x16 | FIFO_STATUS | `fifo_status` | FIFO |
| 0x17 | FIFO_DATA | `fifo_data` | FIFO |
| 0x2D | STATUSINT | `statusint` | Status |
| 0x2E | STATUS0 | `status0` | Status |
| 0x2F | STATUS1 | `status1` | Status |
| 0x30 | TIMESTAMP_LOW | `timestamp_low` | Timestamp |
| 0x31 | TIMESTAMP_MID | `timestamp_mid` | Timestamp |
| 0x32 | TIMESTAMP_HIGH | `timestamp_high` | Timestamp |
| 0x33 | TEMP_L | `temp_l` | Temperature |
| 0x34 | TEMP_H | `temp_h` | Temperature |
| 0x35 | AX_L | `ax_l` | Accel Data |
| 0x36 | AX_H | `ax_h` | Accel Data |
| 0x37 | AY_L | `ay_l` | Accel Data |
| 0x38 | AY_H | `ay_h` | Accel Data |
| 0x39 | AZ_L | `az_l` | Accel Data |
| 0x3A | AZ_H | `az_h` | Accel Data |
| 0x3B | GX_L | `gx_l` | Gyro Data |
| 0x3C | GX_H | `gx_h` | Gyro Data |
| 0x3D | GY_L | `gy_l` | Gyro Data |
| 0x3E | GY_H | `gy_h` | Gyro Data |
| 0x3F | GZ_L | `gz_l` | Gyro Data |
| 0x40 | GZ_H | `gz_h` | Gyro Data |
| 0x46 | COD_STATUS | `cod_status` | AttitudeEngine |
| 0x49–0x56 | DQW–DVZ | `dqw_l`…`dvz_h` | AttitudeEngine |
| 0x59 | TAP_STATUS | `tap_status` | Motion |
| 0x5A | STEP_CNT_LOW | `step_cnt_low` | Pedometer |
| 0x5B | STEP_CNT_MID | `step_cnt_mid` | Pedometer |
| 0x5C | STEP_CNT_HIGH | `step_cnt_high` | Pedometer |
| 0x60 | RESET | `reset` | Reset |

## Register Details

### 0x00 — WHO_AM_I (Read-Only)

Returns `0x05` for QMI8658C.

### 0x01 — REVISION_ID (Read-Only)

Chip revision identifier.

### 0x02 — CTRL1

| Bit | Name | Description |
|-----|------|-------------|
| 6 | ADDR_AI | Address auto-increment enable (1 = enabled) |
| 1 | SPI_BE | SPI big-endian mode |
| 0 | SPI_AVB | SPI address valid bit |

Driver writes `0x40` (auto-increment enabled).

### 0x03 — CTRL2 (Accelerometer Settings)

| Bit | Name | Description |
|-----|------|-------------|
| 7 | aST | Self test enable |
| 6:4 | aFS | Full scale: 000=±2g, 001=±4g, 010=±8g, 011=±16g |
| 3:0 | aODR | Output data rate (see AccelOdr enum) |

**Accelerometer Sensitivity:**

| Range | LSB/g |
|-------|-------|
| ±2g | 16384 |
| ±4g | 8192 |
| ±8g | 4096 |
| ±16g | 2048 |

### 0x04 — CTRL3 (Gyroscope Settings)

| Bit | Name | Description |
|-----|------|-------------|
| 7 | gST | Self test enable |
| 6:4 | gFS | Full scale: 000=±16dps … 111=±2048dps |
| 3:0 | gODR | Output data rate (see GyroOdr enum) |

**Gyroscope Sensitivity:**

| Range | LSB/dps |
|-------|---------|
| ±16 dps | 2048 |
| ±32 dps | 1024 |
| ±64 dps | 512 |
| ±128 dps | 256 |
| ±256 dps | 128 |
| ±512 dps | 64 |
| ±1024 dps | 32 |
| ±2048 dps | 16 |

### 0x08 — CTRL7 (Sensor Enable)

| Bit | Name | Description |
|-----|------|-------------|
| 1 | gEN | Gyroscope enable |
| 0 | aEN | Accelerometer enable |

Driver writes `0x03` (both enabled) on open, `0x00` on close.

### 0x2E — STATUS0

| Bit | Name | Description |
|-----|------|-------------|
| 1 | GDA | Gyroscope data available |
| 0 | ADA | Accelerometer data available |

`isDataReady()` checks `(status & 0x03) == 0x03`.

### 0x33–0x34 — TEMP_L/H

16-bit signed temperature value. Formula: `T = raw / 256 + 25` (°C).

### 0x35–0x40 — Accelerometer + Gyroscope Data

12 bytes, little-endian 16-bit signed:
- 0x35–0x36: AX (accel X)
- 0x37–0x38: AY (accel Y)
- 0x39–0x3A: AZ (accel Z)
- 0x3B–0x3C: GX (gyro X)
- 0x3D–0x3E: GY (gyro Y)
- 0x3F–0x40: GZ (gyro Z)

### 0x60 — RESET

| Value | Meaning |
|-------|---------|
| 0xB0 | Software reset |

After writing 0xB0, wait ≥10ms before further configuration.

## Driver Register Usage Quick Reference

| API | Registers Written |
|-----|-------------------|
| `open()` | 0x00 (read), 0x60, 0x02, 0x08, 0x03, 0x04 |
| `close()` | 0x08 |
| `readRaw()` | 0x35–0x40 (burst read) |
| `readTemperature()` | 0x33–0x34 |
| `setAccelRange()` | 0x03 |
| `setGyroRange()` | 0x04 |
| `selfTest()` | 0x00 (read) |
| `isDataReady()` | 0x2E (read) |
