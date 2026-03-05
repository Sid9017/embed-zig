# TCA9554 / TCA9554A Register Map

Texas Instruments TCA9554 / TCA9554A — 8-Bit I2C I/O Expander with Interrupt.
Datasheet: SCPS209E, Revised April 2023.

I2C address (7-bit):
- TCA9554: `0100_xxx` → 0x20–0x27 (A2:A1:A0 pins)
- TCA9554A: `0111_0xx` → 0x38–0x3F (A2:A1:A0 pins)

## Register Summary

| Addr | Name | Default | R/W | Description |
|------|------|---------|-----|-------------|
| 0x00 | Input Port | — | R | Reflects actual pin levels |
| 0x01 | Output Port | 0xFF | R/W | Output latch register |
| 0x02 | Polarity Inversion | 0x00 | R/W | Input polarity inversion |
| 0x03 | Configuration | 0xFF | R/W | I/O direction (0=output, 1=input) |

## Register Details

### 0x00 — Input Port (Read-Only)

| Bit | Name | Description |
|-----|------|-------------|
| 7:0 | P7–P0 | Current logic level of each pin |

Reading this register returns the actual pin state. For output pins, the value
reflects the output latch unless externally driven. Polarity inversion (register
0x02) applies before the value is returned.

### 0x01 — Output Port

| Bit | Name | Default | Description |
|-----|------|---------|-------------|
| 7:0 | P7–P0 | 0xFF | Output level for each pin configured as output |

Writing to this register sets the output latch. Pins configured as input are
unaffected but the latch value is stored. Default is all high (0xFF).

### 0x02 — Polarity Inversion

| Bit | Name | Default | Description |
|-----|------|---------|-------------|
| 7:0 | P7–P0 | 0x00 | 0 = normal, 1 = inverted input polarity |

When a bit is set, the corresponding Input Port bit is inverted before being
read. Only affects input reads, not output values.

### 0x03 — Configuration

| Bit | Name | Default | Description |
|-----|------|---------|-------------|
| 7:0 | P7–P0 | 0xFF | 0 = output, 1 = input |

Default is all inputs (0xFF). Setting a bit to 0 configures that pin as an
output driven by the Output Port register.

## Pin Mapping

| Bit | Pin | Mask |
|-----|-----|------|
| 0 | P0 | 0x01 |
| 1 | P1 | 0x02 |
| 2 | P2 | 0x04 |
| 3 | P3 | 0x08 |
| 4 | P4 | 0x10 |
| 5 | P5 | 0x20 |
| 6 | P6 | 0x40 |
| 7 | P7 | 0x80 |

## Driver Register Usage Quick Reference

| API | Register | Operation |
|-----|----------|-----------|
| `setDirection()` | 0x03 | Read-modify-write config cache |
| `setDirectionMask()` | 0x03 | Write inverted mask |
| `write()` | 0x01 | Read-modify-write output cache |
| `writeMask()` | 0x01 | Masked write output cache |
| `writeAll()` | 0x01 | Full write |
| `read()` | 0x00 | Read input, extract pin bit |
| `readAll()` | 0x00 | Read full input port |
| `toggle()` | 0x01 | XOR output cache |
| `setPolarity()` | 0x02 | Read-modify-write |
| `reset()` | 0x01, 0x02, 0x03 | Write defaults |
| `syncFromDevice()` | 0x01, 0x03 | Read into cache |
| `configureMultiple()` | 0x01, 0x03 | Write output + config |

## Notes

- The driver caches output (0x01) and config (0x03) registers to avoid
  read-modify-write I2C transactions on every pin operation.
- Call `syncFromDevice()` after external reset or power cycle to re-sync caches.
- The INT output (active low, open-drain) fires on any input change vs. the
  last read of the Input Port register. Reading the Input Port clears the interrupt.
