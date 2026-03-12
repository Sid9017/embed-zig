# 4G Cellular Module Plan

> Status: DISCUSSING | Last updated: 2026-03-12 Round 19

---

## 1. Background & Goal

Add external 4G modem (Quectel series) support to the embedded platform.
Cross-platform: ESP32, Beken, Linux/RPi, macOS, Windows, Test (mock).
Reference: `x/c/esp/components/quectel` (C, ESP-IDF).

---

## 2. Design Decisions Summary

| Round | Decision |
|-------|----------|
| R3  | NO new HAL contract. All modem logic in pkg layer, pure Zig |
| R4  | PPP handled by lwIP, we provide data channel read/write |
| R5  | Modem is opaque abstraction, CMUX is internal detail |
| R8  | State machine uses flux pattern (Event -> reducer -> State) |
| R10 | PPP-link-up state named `connected` |
| R12 | ModemState has 7 phases: off/starting/ready/sim_ready/registering/connected/error |
| R14 | modem.zig belongs in pkg, not hal |
| R15 | Package named `cellular`, core type named `Modem` |
| R16 | Modem accepts generic Io, not UART. Supports UART/USB/SPI via Io abstraction |

---

## 3. Architecture

### 3.1 Transport abstraction (Io strategy)

4G modules connect via different physical interfaces.
All transports are unified through a single `Io` interface (read/write).
Modem does NOT know or care what transport is underneath.

| Transport | Channels | CMUX needed? | Typical platform |
|-----------|----------|-------------|------------------|
| UART      | 1        | Yes         | ESP32, Beken     |
| SPI       | 1        | Yes         | Low-power embedded |
| USB       | 4 virtual serial ports | No | Linux, RPi, Mac, Win |

**Io abstraction原则：**
- `Io` 是唯一的跨平台边界。上层 `pkg/cellular` 全部是纯 Zig，只依赖 `Io`。
- 下层平台代码负责将具体硬件包装为 `Io`：
  - 嵌入式：通过 `io.fromUart()` / `io.fromSpi()` 包装 HAL 驱动
  - Linux/Mac/Win：通过 POSIX `open()` 或平台 API 打开串口设备文件，包装为 `Io`
  - 测试：通过 `MockIo`（ring buffer）模拟任意通道

**USB 端口映射（以 Quectel EC25/EC20 为例）：**

| USB Port | Linux 设备 | macOS 设备 | 功能 |
|----------|-----------|-----------|------|
| ttyUSB0 / cu.usbserial-0 | /dev/ttyUSB0 | /dev/cu.usbserial-*0 | DM (诊断/固件升级) |
| ttyUSB1 / cu.usbserial-1 | /dev/ttyUSB1 | /dev/cu.usbserial-*1 | NMEA (GPS 数据) |
| ttyUSB2 / cu.usbserial-2 | /dev/ttyUSB2 | /dev/cu.usbserial-*2 | AT 指令端口 |
| ttyUSB3 / cu.usbserial-3 | /dev/ttyUSB3 | /dev/cu.usbserial-*3 | Modem/PPP 数据端口 |

USB 天然提供独立的 AT 和 PPP 端口，无需 CMUX 复用。
用户将 ttyUSB2 包装为 `at_io`，ttyUSB3 包装为 `data_io` 即可。

**真机测试支持：**
Mac/Linux 通过 USB 接 4G 模组后，可直接用 `zig test` 进行真机集成测试。
通过环境变量控制是否启用真机测试，平时只跑 MockIo 测试。

### 3.2 Two operating modes

```
Mode 1: Single-channel (UART, SPI)
  Caller provides one Io.
  Modem uses CMUX internally to split into AT + PPP virtual channels.

  [caller] -> Modem.init(.{ .io = uart_io })

  Internal:
    uart_io -> [CMUX] -> AT channel (Io)  -> AtEngine
                       -> PPP channel (Io) -> pppIo()

Mode 2: Multi-channel (USB, or any pre-split transport)
  Caller provides separate AT Io and data Io.
  Modem routes directly, no CMUX.

  [caller] -> Modem.init(.{ .at_io = usb_at_port, .data_io = usb_data_port })

  Internal:
    usb_at_port   -> AtEngine
    usb_data_port -> pppIo()
```

Modem auto-detects mode based on what is provided:
- `data_io != null` -> multi-channel mode, CMUX skipped entirely
- `data_io == null` -> single-channel mode, CMUX used when entering data mode

### 3.3 Layer diagram

```
+-----------------------------------------------------------+
|                      pkg/cellular/                         |
|                                                            |
|  modem.zig -- core abstraction                             |
|    owns: Io(s), CMUX (optional), AtEngine, flux Store      |
|    exposes: .at(), .pppIo(), .dispatch(), .getState()      |
|                                                            |
|  sim.zig / signal.zig / voice.zig                          |
|    use modem.at() to send AT commands                      |
|                                                            |
|  at.zig -- AT engine (reads/writes through Io)             |
|  cmux.zig -- CMUX framing (only used in single-ch mode)   |
|  at_parse.zig -- pure parsing functions                    |
|  io.zig -- generic Io interface definition                 |
|  types.zig -- all shared types                             |
+-----------------------------------------------------------+
|                    Io boundary                             |
|  Everything above is pure Zig, transport-agnostic.         |
|  Everything below is platform-specific.                    |
+-----------------------------------------------------------+
|  Platform provides Io implementations:                     |
|                                                            |
|  ESP32:   UART HAL driver -> Io    (single-channel)        |
|  Beken:   UART HAL driver -> Io    (single-channel)        |
|  Linux:   /dev/ttyUSB0 -> at_io    (multi-channel)         |
|           /dev/ttyUSB1 -> data_io                          |
|  macOS:   /dev/cu.* -> at_io + data_io                     |
|  Windows: COM3 -> at_io, COM4 -> data_io                   |
|  Test:    MockIo (ring buffer)                             |
+-----------------------------------------------------------+
|  lwIP PPP (external)                                       |
|  Consumes modem.pppIo() for PPP framing                   |
+-----------------------------------------------------------+
```

---

## 4. Directory Tree

```
src/pkg/cellular/
|-- types.zig          shared types (no logic, no deps)
|-- io.zig             generic Io interface
|-- at_parse.zig       AT response parsing (pure functions)
|-- at.zig             AT command engine
|-- cmux.zig           GSM 07.10 CMUX framing
|-- modem.zig          core Modem (owns everything, flux reducer)
|-- sim.zig            SIM card management
|-- signal.zig         signal quality monitoring
|-- voice.zig          voice call management (phase 2)
|-- apn.zig            APN auto-resolve (phase 2)
```

Changes to existing files:
```
src/mod.zig            add pkg.cellular exports
```

No HAL changes. No runtime changes.

---

## 5. File-by-File Specification

### 5.1 types.zig

All shared types. No logic, no dependencies.

```zig
Phase = enum { off, starting, ready, sim_ready, registering, connected, error };
SimStatus = enum { not_inserted, pin_required, puk_required, ready, error };
NetworkType = enum { none, gsm, gprs, edge, umts, hsdpa, lte };
RegistrationStatus = enum { not_registered, registered_home, searching, denied, registered_roaming, unknown };
CallState = enum { idle, incoming, dialing, alerting, active };

SignalInfo = struct {
    rssi: i8,
    ber: ?u8,
    rsrp: ?i16,
    rsrq: ?i8,
};

ModemInfo = struct {
    imei: [15]u8,    imei_len: u8,
    model: [32]u8,   model_len: u8,
    firmware: [32]u8, firmware_len: u8,
    pub fn getImei(self: *const @This()) []const u8;
    pub fn getModel(self: *const @This()) []const u8;
    pub fn getFirmware(self: *const @This()) []const u8;
};

SimInfo = struct {
    status: SimStatus,
    imsi: [15]u8,  imsi_len: u8,
    iccid: [20]u8, iccid_len: u8,
    pub fn getImsi(self: *const @This()) []const u8;
    pub fn getIccid(self: *const @This()) []const u8;
};

ModemState = struct {
    phase: Phase = .off,
    sim: SimStatus = .not_inserted,
    registration: RegistrationStatus = .not_registered,
    network_type: NetworkType = .none,
    signal: ?SignalInfo = null,
    modem_info: ?ModemInfo = null,
    sim_info: ?SimInfo = null,
    error_count: u8 = 0,
};

ModemEvent = union(enum) {
    power_on: void,
    power_off: void,
    at_ready: void,
    at_timeout: void,
    sim_ready: void,
    sim_error: SimStatus,
    sim_removed: void,
    pin_required: void,
    registered: RegistrationStatus,
    registration_failed: RegistrationStatus,
    dial_connected: void,
    dial_failed: void,
    ip_obtained: void,
    ip_lost: void,
    signal_updated: SignalInfo,
    error_recovery: void,
    stop: void,
};

ConnectConfig = struct {
    apn: []const u8,
    username: []const u8 = "",
    password: []const u8 = "",
};

ChannelRole = enum { at, ppp };

ChannelConfig = struct {
    dlci: u8,
    role: ChannelRole,
};

ModemConfig = struct {
    -- CMUX settings (only used in single-channel mode)
    cmux_channels: []const ChannelConfig = &.{
        .{ .dlci = 1, .role = .ppp },
        .{ .dlci = 2, .role = .at },
    },
    cmux_baud_rate: u32 = 921600,

    -- AT engine settings
    at_timeout_ms: u32 = 5000,
    max_urc_handlers: u8 = 16,
};
```

### 5.2 io.zig

Type-erased read/write interface. The universal transport abstraction.

```zig
pub const IoError = error{ WouldBlock, Timeout, Closed, IoError };

pub const Io = struct {
    ctx: *anyopaque,
    readFn: *const fn (*anyopaque, []u8) IoError!usize,
    writeFn: *const fn (*anyopaque, []const u8) IoError!usize,

    pub fn read(self: Io, buf: []u8) IoError!usize;
    pub fn write(self: Io, buf: []const u8) IoError!usize;
};

-- Helpers to wrap HAL types into Io
pub fn fromUart(comptime UartType: type, ptr: *UartType) Io;
pub fn fromSpi(comptime SpiType: type, ptr: *SpiType) Io;

-- Helper for testing
pub fn fromBufferPair(tx: *RingBuffer, rx: *RingBuffer) Io;
```

### 5.3 at_parse.zig

Pure parsing functions. No state, no IO, no dependencies except types.zig.
Extracted for independent testability.

```zig
pub fn isOk(line: []const u8) bool;
pub fn isError(line: []const u8) bool;
pub fn parseCmeError(line: []const u8) ?u16;
pub fn parseCmsError(line: []const u8) ?u16;
pub fn parsePrefix(line: []const u8, prefix: []const u8) ?[]const u8;
pub fn parseCsq(value: []const u8) ?SignalInfo;
pub fn parseCpin(value: []const u8) ?SimStatus;
pub fn parseCreg(value: []const u8) ?RegistrationStatus;
pub fn rssiToDbm(csq: u8) i8;
pub fn rssiToPercent(dbm: i8) u8;
```

### 5.4 at.zig

AT command engine. Reads/writes through Io. Transport-agnostic.

```zig
pub const AtStatus = enum { ok, error, cme_error, cms_error, timeout };

pub const AtResponse = struct {
    status: AtStatus,
    lines: [8][128]u8,
    line_count: u8,
    error_code: ?u16,
    pub fn getLine(self: *const @This(), idx: u8) ?[]const u8;
    pub fn firstLine(self: *const @This()) ?[]const u8;
};

pub const UrcHandler = struct {
    prefix: []const u8,
    ctx: ?*anyopaque,
    callback: *const fn (?*anyopaque, []const u8) void,
};

pub const AtEngine = struct {
    io: Io,
    rx_buf: [1024]u8,
    rx_pos: usize,
    urc_handlers: [16]?UrcHandler,

    pub fn init(io: Io) AtEngine;
    pub fn setIo(self: *AtEngine, io: Io) void;
    pub fn send(self: *AtEngine, cmd: []const u8, timeout_ms: u32) AtResponse;
    pub fn registerUrc(self: *AtEngine, prefix: []const u8, handler: UrcHandler) bool;
    pub fn unregisterUrc(self: *AtEngine, prefix: []const u8) void;
    pub fn pumpUrcs(self: *AtEngine) void;
};
```

### 5.5 cmux.zig

GSM 07.10 CMUX framing. Only used internally by Modem in single-channel mode.

```zig
pub const Frame = struct {
    dlci: u8,
    control: u8,
    data: []const u8,
};

pub fn Cmux(comptime max_channels: u8) type {
    return struct {
        io: Io,                                -- underlying single-channel transport
        channels: [max_channels]ChannelBuf,
        active: bool,

        pub fn init(io: Io) @This();
        pub fn open(dlcis: []const u8) !void;
        pub fn close(self: *@This()) void;
        pub fn channelIo(self: *@This(), dlci: u8) ?Io;
        pub fn pump(self: *@This()) void;

        pub fn encodeFrame(frame: Frame, out: []u8) usize;
        pub fn decodeFrame(data: []const u8) ?Frame;
        pub fn calcFcs(data: []const u8) u8;
    };
}
```

### 5.6 modem.zig

The core abstraction. Owns transport, CMUX, AT engine, flux store.

```zig
pub const InitConfig = struct {
    -- Single-channel mode: provide io only. CMUX used internally.
    io: ?Io = null,

    -- Multi-channel mode: provide both. CMUX skipped.
    at_io: ?Io = null,
    data_io: ?Io = null,

    -- Modem settings
    config: ModemConfig = .{},
};

pub const Modem = struct {
    mode: enum { single_channel, multi_channel },
    raw_io: ?Io,                   -- original single-channel Io (for CMUX)
    cmux: ?Cmux(4),                -- only in single-channel mode
    at_engine: AtEngine,
    data_io: ?Io,                  -- PPP data channel (CMUX ch or direct)
    store: Store(ModemState, ModemEvent),
    config: ModemConfig,

    pub fn init(cfg: InitConfig) Modem;
    pub fn deinit(self: *Modem) void;

    -- Flux store
    pub fn dispatch(self: *Modem, event: ModemEvent) void;
    pub fn getState(self: *const Modem) *const ModemState;
    pub fn getPrev(self: *const Modem) *const ModemState;
    pub fn isDirty(self: *const Modem) bool;
    pub fn commitFrame(self: *Modem) void;

    -- AT channel
    pub fn at(self: *Modem) *AtEngine;

    -- PPP data IO (for lwIP)
    pub fn pppIo(self: *Modem) ?Io;
        Returns:
        - multi-channel: data_io (always available after init)
        - single-channel: CMUX data channel Io (available after enterCmux)
        - null if data channel not yet established

    -- CMUX lifecycle (single-channel mode only)
    pub fn enterCmux(self: *Modem) !void;
        Single-channel: sends AT+CMUX=0, opens DLCIs, swaps AT engine Io.
        Multi-channel: no-op (already separated).

    pub fn exitCmux(self: *Modem) void;
        Single-channel: sends DISC, restores AT engine Io to raw transport.
        Multi-channel: no-op.

    pub fn isCmuxActive(self: *const Modem) bool;

    -- Data mode
    pub fn enterDataMode(self: *Modem) !void;
        Sends ATD*99#, waits for CONNECT.
        After this, pppIo() returns the data stream.

    pub fn exitDataMode(self: *Modem) void;
        Sends +++ or ATH to exit data mode.

    -- Pump (must be called periodically)
    pub fn pump(self: *Modem) void;
        Single-channel + CMUX active: demuxes incoming bytes to channels.
        Multi-channel: no-op (channels are independent).

    -- Reducer (internal, pure logic)
    fn reduce(state: *ModemState, event: ModemEvent) void;
};
```

### 5.7 sim.zig

SIM card management. Sends AT commands via AtEngine.

```zig
pub const Sim = struct {
    at: *AtEngine,

    pub fn init(at_engine: *AtEngine) Sim;
    pub fn getStatus(self: *Sim) !SimStatus;
    pub fn getImsi(self: *Sim) !SimInfo;
    pub fn getIccid(self: *Sim) !SimInfo;
    pub fn enterPin(self: *Sim, pin: []const u8) !void;
    pub fn enableHotplug(self: *Sim) !void;
    pub fn registerUrcs(self: *Sim, dispatch_ctx: anytype) void;
};
```

### 5.8 signal.zig

Signal quality monitoring. Sends AT commands via AtEngine.

```zig
pub const Signal = struct {
    at: *AtEngine,

    pub fn init(at_engine: *AtEngine) Signal;
    pub fn getStrength(self: *Signal) !SignalInfo;
    pub fn getRegistration(self: *Signal) !RegistrationStatus;
    pub fn getNetworkType(self: *Signal) !NetworkType;
};
```

### 5.9 voice.zig (phase 2)

```zig
pub const Voice = struct {
    at: *AtEngine,
    pub fn init(at_engine: *AtEngine) Voice;
    pub fn dial(self: *Voice, number: []const u8) !void;
    pub fn answer(self: *Voice) !void;
    pub fn hangup(self: *Voice) !void;
    pub fn getCallState(self: *Voice) !CallState;
    pub fn registerUrcs(self: *Voice, dispatch_ctx: anytype) void;
};
```

### 5.10 apn.zig (phase 2)

```zig
pub fn resolve(imsi: []const u8) ?[]const u8;
```

---

## 6. Reducer

Pure function. All state transitions centralized here.

```
fn reduce(state: *ModemState, event: ModemEvent) void {
    switch (state.phase) {
        .off => switch (event) {
            .power_on => state.phase = .starting,
            else => {},
        },
        .starting => switch (event) {
            .at_ready   => { state.phase = .ready; state.error_count = 0; },
            .at_timeout => { state.phase = .error; state.error_count += 1; },
            .stop       => state.phase = .off,
            else => {},
        },
        .ready => switch (event) {
            .sim_ready  => state.phase = .sim_ready,
            .sim_error  => |s| { state.sim = s; state.phase = .error; },
            .stop       => state.phase = .off,
            else => {},
        },
        .sim_ready => switch (event) {
            .registered          => |r| { state.registration = r; state.phase = .registering; },
            .registration_failed => |r| { state.registration = r; state.phase = .error; },
            .sim_removed         => { state.sim = .not_inserted; state.phase = .ready; },
            .stop                => state.phase = .off,
            else => {},
        },
        .registering => switch (event) {
            .dial_connected => state.phase = .connected,
            .dial_failed    => state.phase = .error,
            .sim_removed    => { state.sim = .not_inserted; state.phase = .ready; },
            .stop           => state.phase = .off,
            else => {},
        },
        .connected => switch (event) {
            .ip_lost     => state.phase = .registering,
            .sim_removed => { state.sim = .not_inserted; state.phase = .ready; },
            .stop        => state.phase = .off,
            else => {},
        },
        .error => switch (event) {
            .error_recovery => state.phase = .starting,
            .stop           => state.phase = .off,
            else => {},
        },
    }
    -- Cross-cutting updates
    switch (event) {
        .signal_updated => |s| state.signal = s,
        .sim_ready      => state.sim = .ready,
        .sim_removed    => state.sim = .not_inserted,
        else => {},
    }
}
```

---

## 7. Usage Examples

### 7.1 ESP32 (UART, single-channel)

```
const uart_io = io.fromUart(UartDriver, &uart_driver);
var modem = Modem.init(.{ .io = uart_io });

-- Single Io provided -> Modem uses CMUX internally
-- modem.enterCmux() splits into AT + PPP channels
-- modem.pppIo() returns CMUX data channel for lwIP
```

### 7.2 Linux (USB, multi-channel)

```
const at_io = linux_serial.open("/dev/ttyUSB1");   -- AT port
const data_io = linux_serial.open("/dev/ttyUSB0"); -- data port
var modem = Modem.init(.{ .at_io = at_io, .data_io = data_io });

-- Two Io provided -> no CMUX needed
-- modem.at() uses at_io directly
-- modem.pppIo() returns data_io directly
-- modem.enterCmux() is a no-op
```

### 7.3 Test (mock)

```
var mock_at = MockIo.init();
var mock_data = MockIo.init();
var modem = Modem.init(.{ .at_io = mock_at.io(), .data_io = mock_data.io() });

-- Or test single-channel mode:
var mock_uart = MockIo.init();
var modem = Modem.init(.{ .io = mock_uart.io() });
```

---

## 8. Test Plan

### 8.1 MockIo

The universal test transport. Simulates any channel (UART, USB port, CMUX virtual channel).

```
MockIo:
    tx: RingBuffer(1024)   -- bytes written by our code
    rx: RingBuffer(1024)   -- bytes read by our code

    pub fn init() MockIo;
    pub fn io(self: *MockIo) Io;           -- returns Io backed by this mock

    -- Test helpers
    pub fn feed(self: *MockIo, bytes: []const u8) void;  -- inject response
    pub fn sent(self: *MockIo) []const u8;                -- read what was sent
    pub fn drain(self: *MockIo) void;                     -- clear tx buffer

    -- Auto-responder
    pub fn onSend(self: *MockIo, trigger: []const u8, response: []const u8) void;
```

### 8.2 types.zig (3 tests)

| ID    | Test | Validates |
|-------|------|-----------|
| TY-01 | ModemState default | phase=.off, sim=.not_inserted, error_count=0 |
| TY-02 | ModemInfo getters | getImei/getModel/getFirmware slice correctness |
| TY-03 | SimInfo getters | getImsi/getIccid slice correctness |

### 8.3 io.zig (3 tests)

| ID    | Test | Validates |
|-------|------|-----------|
| IO-01 | Io round-trip | write bytes -> read bytes through mock-backed Io |
| IO-02 | fromUart | UART HAL wrapped as Io, read/write pass through |
| IO-03 | WouldBlock | empty read returns WouldBlock |

### 8.4 at_parse.zig (11 tests)

| ID    | Test | Validates |
|-------|------|-----------|
| AP-01 | isOk | "OK"->true, "ERROR"->false |
| AP-02 | isError | "ERROR"->true, "+CME ERROR: 10"->false |
| AP-03 | parseCmeError | "+CME ERROR: 10"->10 |
| AP-04 | parseCmsError | "+CMS ERROR: 500"->500 |
| AP-05 | parsePrefix | "+CSQ: 20,0" with "+CSQ:" -> "20,0" |
| AP-06 | parseCsq | "20,0" -> rssi=-73, ber=0 |
| AP-07 | parseCsq no signal | "99,99" -> null |
| AP-08 | parseCpin | "READY"->.ready, "SIM PIN"->.pin_required |
| AP-09 | parseCreg | "0,1"->.registered_home, "0,5"->.registered_roaming |
| AP-10 | rssiToDbm | 20->-73, 0->-113, 31->-51 |
| AP-11 | rssiToPercent | -50->100, -110->0, -80->50 |

### 8.5 at.zig (11 tests, uses MockIo)

| ID    | Test | Validates |
|-------|------|-----------|
| AT-01 | basic OK | "AT\r" sent -> "\r\nOK\r\n" -> status=ok |
| AT-02 | response with data | "+CSQ: 20,0\r\nOK\r\n" -> line parsed |
| AT-03 | ERROR | "ERROR\r\n" -> status=error |
| AT-04 | CME ERROR | "+CME ERROR: 10\r\n" -> code=10 |
| AT-05 | timeout | no response -> status=timeout |
| AT-06 | URC idle | register prefix -> feed URC -> pumpUrcs -> called |
| AT-07 | URC interleaved | URC mixed in response -> both handled |
| AT-08 | partial reassembly | "O" then "K\r\n" -> complete response |
| AT-09 | multi-line | 4 lines + OK -> all captured |
| AT-10 | setIo swap | Io A -> swap to B -> correct routing |
| AT-11 | multiple URCs | 3 prefixes -> correct dispatch |

### 8.6 cmux.zig (10 tests, uses MockIo)

| ID    | Test | Validates |
|-------|------|-----------|
| MX-01 | UIH encode | data -> GSM 07.10 byte sequence |
| MX-02 | UIH decode | raw bytes -> Frame { dlci, payload } |
| MX-03 | SABM/UA handshake | open() -> SABM sent -> feed UA -> success |
| MX-04 | channel write | channelIo(2).write("AT") -> UIH DLCI=2 |
| MX-05 | channel read | feed UIH DLCI=2 -> channelIo(2).read -> data |
| MX-06 | channel isolation | DLCI 1 data not on DLCI 2 |
| MX-07 | DISC/close | close() -> DISC frames sent |
| MX-08 | FCS | known GSM 07.10 vectors |
| MX-09 | concurrent | interleaved DLCI 1+2 -> correct muxing |
| MX-10 | pump demux | mixed frames -> correct channel buffers |

### 8.7 modem.zig routing tests (13 tests)

| ID    | Test | Validates |
|-------|------|-----------|
| MD-01 | single-ch init | .io provided -> single_channel mode |
| MD-02 | multi-ch init | .at_io + .data_io -> multi_channel mode |
| MD-03 | invalid init | neither io nor at_io -> error |
| MD-04 | single-ch AT | at().send("AT") -> bytes on raw Io |
| MD-05 | multi-ch AT | at().send("AT") -> bytes on at_io only |
| MD-06 | multi-ch PPP | pppIo().write -> bytes on data_io only |
| MD-07 | multi-ch pppIo available | pppIo() != null immediately |
| MD-08 | single-ch enterCmux | AT+CMUX=0 sent, SABM/UA, Io swapped |
| MD-09 | single-ch CMUX AT | after CMUX -> at().send -> CMUX DLCI 2 |
| MD-10 | single-ch CMUX PPP | after CMUX -> pppIo() -> CMUX DLCI 1 |
| MD-11 | single-ch exitCmux | DISC sent, AT back to raw Io |
| MD-12 | multi-ch enterCmux noop | enterCmux() is no-op in multi-ch mode |
| MD-13 | enterDataMode | ATD*99# -> CONNECT -> pppIo active |

### 8.8 modem.zig reducer tests (18 tests, pure logic, no IO)

| ID    | Test | Validates |
|-------|------|-----------|
| MR-01 | off -> power_on -> starting | |
| MR-02 | starting -> at_ready -> ready | error_count reset |
| MR-03 | starting -> at_timeout -> error | error_count++ |
| MR-04 | ready -> sim_ready -> sim_ready | sim = .ready |
| MR-05 | ready -> sim_error -> error | sim status stored |
| MR-06 | sim_ready -> registered -> registering | reg stored |
| MR-07 | sim_ready -> reg_failed -> error | |
| MR-08 | sim_ready -> sim_removed -> ready | sim reset |
| MR-09 | registering -> dial_connected -> connected | |
| MR-10 | registering -> dial_failed -> error | |
| MR-11 | connected -> ip_lost -> registering | reconnect |
| MR-12 | connected -> sim_removed -> ready | teardown |
| MR-13 | connected -> signal_updated | signal stored, phase unchanged |
| MR-14 | connected -> stop -> off | shutdown |
| MR-15 | error -> error_recovery -> starting | retry |
| MR-16 | error -> stop -> off | |
| MR-17 | any phase -> stop -> off | universal |
| MR-18 | ignored events | wrong event for phase -> no change |

### 8.9 sim.zig (7 tests)

| ID    | Test | Validates |
|-------|------|-----------|
| SM-01 | SIM ready | AT+CPIN? -> "+CPIN: READY" -> .ready |
| SM-02 | not inserted | -> "+CME ERROR: 10" -> .not_inserted |
| SM-03 | PIN required | -> "+CPIN: SIM PIN" -> .pin_required |
| SM-04 | IMSI | AT+CIMI -> "460001234567890" |
| SM-05 | ICCID | AT+QCCID -> "+QCCID: 89860..." |
| SM-06 | hotplug URC | "+QSIMSTAT: 0,0" -> removal |
| SM-07 | PIN entry | "AT+CPIN=1234\r" sent -> OK |

### 8.10 signal.zig (7 tests)

| ID    | Test | Validates |
|-------|------|-----------|
| SG-01 | CSQ | "+CSQ: 20,0" -> rssi=-73 |
| SG-02 | no signal | "+CSQ: 99,99" -> null |
| SG-03 | LTE quality | AT+QCSQ -> rsrp/rsrq |
| SG-04 | reg home | "+CGREG: 0,1" -> registered_home |
| SG-05 | reg roaming | "+CEREG: 0,5" -> registered_roaming |
| SG-06 | reg denied | "+CGREG: 0,3" -> denied |
| SG-07 | network type | AT+QNWINFO -> .lte |

**Total: 83 test cases**

---

## 9. Implementation Plan (Step-by-Step)

### 验证方式说明

每一步开发完成后必须验证。验证分两种方式：

| 方式 | 说明 | 适用场景 |
|------|------|----------|
| **烧录验证** | 编译固件烧录到 ESP32S3，通过 UART 连接真实 4G 模组，串口 log 输出结果 | 涉及 IO 交互的所有步骤 |
| **Mock 验证** | 在开发机上运行 `zig test`，用 MockIo（ring buffer）模拟通道 | 纯类型定义、纯函数、纯状态机逻辑 |

**原则：能烧录验证就烧录验证。只有完全没有硬件交互的纯计算逻辑才用 Mock。**

### 硬件准备

在开始之前，需要准备以下硬件：

- ESP32S3 开发板 x1
- Quectel 4G 模组（EC25/EC20/EG25 等）x1
- 可用的 SIM 卡（已激活，有数据流量）x1
- UART 连接线（TX/RX/GND，如需硬件流控还需 RTS/CTS）
- USB 数据线（用于烧录固件和查看串口 log）

ESP32S3 与 4G 模组的 UART 接线：

| ESP32S3 引脚 | 4G 模组引脚 | 说明 |
|-------------|------------|------|
| TXD (GPIO X) | RXD | ESP32 发送 → 模组接收 |
| RXD (GPIO X) | TXD | 模组发送 → ESP32 接收 |
| GND | GND | 共地 |
| RTS (GPIO X) | CTS | 可选，硬件流控 |
| CTS (GPIO X) | RTS | 可选，硬件流控 |

> 具体 GPIO 编号在 Step 0 的 board_hw.zig 中配置，根据实际开发板确定。

### 固件工程结构

所有烧录验证步骤共用一个递增式固件工程，分布在两个目录中：

**两个目录的职责划分：**

| 目录 | 职责 | 修改频率 |
|------|------|----------|
| `test/firmware/110-cellular/` | 平台无关的验证逻辑（app.zig + board_spec.zig） | 每个 Step 追加 |
| `test/esp/110-cellular/` | ESP32 特定的构建和硬件绑定（build.zig、引脚配置、main.zig） | Step 0 一次性搭建 |

`test/firmware/` 下的代码不依赖任何平台特定 API，只通过 `board_spec.zig` 声明
需要哪些 HAL 外设。`test/esp/` 下的代码负责将 ESP32 的具体硬件实现绑定进来。

**编译链路：**

```
test/firmware/110-cellular/app.zig       ← 开发者写验证逻辑的地方
        ↓ 被 main.zig 引用
test/esp/110-cellular/src/main.zig       ← 固件入口，调用 app.run(hw, env)
        ↓ build.zig 编译
ESP32S3 固件 (.bin)                      ← 烧录到开发板
        ↓ 串口输出
开发者通过终端观察 log                     ← 判断是否通过
```

**目录树：**

```
test/firmware/110-cellular/
├── app.zig              -- 验证逻辑入口，每一步追加代码（平台无关）
├── board_spec.zig       -- 声明所需 HAL 外设（UART）

test/esp/110-cellular/
├── build.zig            -- ESP-IDF 构建配置（Step 0 创建，后续不改）
├── build.zig.zon        -- 依赖声明
├── board/
│   ├── esp32s3_devkit.zig      -- sdkconfig
│   └── esp32s3_devkit_hw.zig   -- 硬件引脚配置（UART TX/RX/RTS/CTS）
└── src/
    └── main.zig         -- zig_esp_main 入口，调用 app.run()
```

**开发流程：**
1. 每完成一个 Step，在 `test/firmware/110-cellular/app.zig` 中追加对应的验证代码
2. 重新编译烧录固件
3. 通过串口终端（如 `idf.py monitor` 或 `minicom`）观察 log 输出
4. 对照该 Step 的"通过标准"判断是否成功

---

### Step 0: 基础设施 — 硬件通路验证

**目标：** 确认 ESP32S3 能通过 UART 和 4G 模组进行原始字节收发。

**验证方式：烧录验证**

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/pkg/cellular/` | 创建目录 | cellular 包根目录 |
| `test/firmware/110-cellular/app.zig` | 新建 | 固件应用入口 |
| `test/firmware/110-cellular/board_spec.zig` | 新建 | 声明 UART HAL 需求 |
| `test/esp/110-cellular/build.zig` | 新建 | ESP-IDF 构建脚本 |
| `test/esp/110-cellular/board/esp32s3_devkit_hw.zig` | 新建 | UART 引脚配置 |
| `test/esp/110-cellular/src/main.zig` | 新建 | zig_esp_main 入口 |
| `test/firmware/mod.zig` | 修改 | 添加 110-cellular 导出 |

**app.zig 验证逻辑：**

```
1. 初始化 UART（连接 4G 模组的引脚，波特率 115200）
2. 通过 UART 发送原始字节 "AT\r\n"
3. 等待 1 秒
4. 读取 UART 返回的原始字节
5. 串口 log 输出：
   [I] cellular test ready
   [I] TX: AT\r\n
   [I] RX: <收到的原始字节，十六进制>
   [I] RX text: <收到的可打印文本>
```

**通过标准：**
- 串口 log 显示 "cellular test ready"
- RX 中能看到模组返回的 "OK" 或 "AT\r\r\nOK\r\n"（具体格式取决于模组回显设置）
- 如果 RX 为空或乱码，检查接线、波特率、模组供电

**注意事项：**
- 4G 模组上电后需要几秒启动时间，app.zig 中应先等待 3-5 秒再发 AT
- 部分模组默认波特率为 115200，部分为 9600，需根据模组手册确认
- 如果模组有 POWER_KEY 引脚，可能需要 GPIO 拉低 1 秒来开机

---

### Step 1: types.zig — 共享类型定义

**目标：** 实现所有共享类型（枚举、结构体），为后续所有文件提供类型基础。

**验证方式：Mock 验证**

**理由：** types.zig 只包含类型定义和简单的 getter 方法，没有任何 IO 交互。
烧录到真机上也无法产生额外的验证价值。

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/pkg/cellular/types.zig` | 新建 | 所有共享类型 |

**实现内容：**
- Phase 枚举（off/starting/ready/sim_ready/registering/connected/error）
- SimStatus / NetworkType / RegistrationStatus / CallState 枚举
- SignalInfo / ModemInfo / SimInfo 结构体（含 getter 方法）
- ModemState 结构体（含默认值）
- ModemEvent tagged union（16 种事件）
- ConnectConfig / ChannelRole / ChannelConfig / ModemConfig 结构体

**测试命令：**

```bash
zig test src/pkg/cellular/types.zig
```

**测试用例（3 个）：**

| ID | 测试名 | 验证内容 |
|----|--------|----------|
| TY-01 | ModemState default | `phase == .off`, `sim == .not_inserted`, `error_count == 0` |
| TY-02 | ModemInfo getters | 写入 IMEI/model/firmware 字节 → getter 返回正确 slice |
| TY-03 | SimInfo getters | 写入 IMSI/ICCID 字节 → getter 返回正确 slice |

**通过标准：** `All 3 tests passed.`

---

### Step 2: io.zig — Io 接口与 UART 包装

**目标：** 实现通用 Io 接口，验证 fromUart 包装后能正确透传数据到真实 4G 模组。

**验证方式：烧录验证**

**理由：** `fromUart()` 将 HAL UART 驱动包装为 Io 接口，必须在真机上验证
包装后的 Io.read() / Io.write() 能正确透传字节到模组。

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/pkg/cellular/io.zig` | 新建 | Io 接口 + fromUart + MockIo |
| `test/firmware/110-cellular/app.zig` | 修改 | 追加 Io 透传验证逻辑 |

**实现内容：**
- `Io` 结构体（ctx + readFn + writeFn，type-erased）
- `Io.read()` / `Io.write()` 方法
- `fromUart(comptime UartType, *UartType) Io` — 将 UART HAL 包装为 Io
- `fromSpi(comptime SpiType, *SpiType) Io` — 将 SPI HAL 包装为 Io
- `MockIo` — 测试用，基于 ring buffer 的 Io 实现
  - `init()` / `io()` / `feed()` / `sent()` / `drain()` / `onSend()`

**Mock 测试命令：**

```bash
zig test src/pkg/cellular/io.zig
```

**Mock 测试用例（3 个）：**

| ID | 测试名 | 验证内容 |
|----|--------|----------|
| IO-01 | Io round-trip | MockIo: write → read → 数据一致 |
| IO-02 | fromUart | Mock UART HAL 包装为 Io，read/write 透传 |
| IO-03 | WouldBlock | 空 MockIo read → 返回 WouldBlock |

**烧录验证逻辑（追加到 app.zig）：**

```
1. 用 io.fromUart() 包装 ESP32 UART HAL 驱动为 Io
2. 通过 Io.write() 发送 "AT\r\n"
3. 等待 500ms
4. 通过 Io.read() 读取返回
5. 串口 log 输出：
   [I] === Step 2: Io interface test ===
   [I] Io.write("AT\r\n") sent 4 bytes
   [I] Io.read() got N bytes: <原始内容>
```

**通过标准：**
- Io.write() 返回 4（成功写入 4 字节）
- Io.read() 返回的内容中包含 "OK"
- 与 Step 0 的原始 UART 结果一致，证明 Io 包装没有引入数据损坏

---

### Step 3: at_parse.zig — AT 响应解析（纯函数）

**目标：** 实现 AT 响应的纯解析函数，无状态、无 IO。

**验证方式：Mock 验证 + 可选烧录验证**

**理由：** at_parse.zig 是纯函数集合，输入字符串输出解析结果，Mock 即可覆盖核心逻辑。
但不同模组返回的响应格式可能有细微差异（多余空格、换行符等），
建议在真机上用模组的真实响应跑一遍解析函数，验证格式兼容性。

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/pkg/cellular/at_parse.zig` | 新建 | 纯解析函数 |

**实现内容：**
- `isOk(line)` — 判断是否为 "OK"
- `isError(line)` — 判断是否为 "ERROR"
- `parseCmeError(line)` — 解析 "+CME ERROR: N" → N
- `parseCmsError(line)` — 解析 "+CMS ERROR: N" → N
- `parsePrefix(line, prefix)` — 提取前缀后的值（如 "+CSQ: 20,0" → "20,0"）
- `parseCsq(value)` — 解析 CSQ 值为 SignalInfo
- `parseCpin(value)` — 解析 CPIN 值为 SimStatus
- `parseCreg(value)` — 解析 CREG/CGREG/CEREG 值为 RegistrationStatus
- `rssiToDbm(csq)` — CSQ 值转 dBm
- `rssiToPercent(dbm)` — dBm 转百分比

**测试命令：**

```bash
zig test src/pkg/cellular/at_parse.zig
```

**测试用例（11 个）：**

| ID | 测试名 | 验证内容 |
|----|--------|----------|
| AP-01 | isOk | "OK" → true, "ERROR" → false |
| AP-02 | isError | "ERROR" → true, "+CME ERROR: 10" → false |
| AP-03 | parseCmeError | "+CME ERROR: 10" → 10 |
| AP-04 | parseCmsError | "+CMS ERROR: 500" → 500 |
| AP-05 | parsePrefix | "+CSQ: 20,0" with "+CSQ:" → "20,0" |
| AP-06 | parseCsq | "20,0" → rssi=-73, ber=0 |
| AP-07 | parseCsq no signal | "99,99" → null |
| AP-08 | parseCpin | "READY" → .ready, "SIM PIN" → .pin_required |
| AP-09 | parseCreg | "0,1" → .registered_home, "0,5" → .registered_roaming |
| AP-10 | rssiToDbm | 20 → -73, 0 → -113, 31 → -51 |
| AP-11 | rssiToPercent | -50 → 100, -110 → 0, -80 → ~50 |

**通过标准：** `All 11 tests passed.`

**可选烧录验证（追加到 app.zig）：**

```
1. 通过 Step 2 的 Io 向模组发送 "AT+CSQ\r\n"，读取原始响应字节
2. 将原始响应逐行传给 at_parse 函数验证：
   [I] === Step 3: at_parse real-device test ===
   [I] Raw response: "+CSQ: 20,0\r\nOK\r\n"
   [I] parsePrefix("+CSQ:") -> "20,0" (ok)
   [I] parseCsq("20,0") -> rssi=-73, ber=0 (ok)
   [I] isOk("OK") -> true (ok)

3. 发送 "AT+CPIN?\r\n"，验证 parseCpin：
   [I] Raw response: "+CPIN: READY\r\nOK\r\n"
   [I] parseCpin("READY") -> .ready (ok)

4. 发送无效指令，验证 error 解析：
   [I] Raw response: "+CME ERROR: 100\r\n"
   [I] parseCmeError -> 100 (ok)
```

**可选烧录通过标准：** 所有解析结果与原始响应内容一致，无格式不兼容。

---

### Step 4: at.zig — AT 指令引擎（核心里程碑 #1）

**目标：** 实现完整的 AT 指令引擎，在真机上完成第一次端到端 AT 指令交互。

**验证方式：烧录验证**

**理由：** AT 引擎是整个 cellular 包的核心 IO 组件。它负责：
- 向模组发送 AT 指令
- 接收并拼装多行响应
- 处理超时
- 识别和分发 URC（主动上报）
这些行为必须在真实模组上验证，因为不同模组的响应时序、换行格式、
URC 插入位置都可能不同。

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/pkg/cellular/at.zig` | 新建 | AT 指令引擎 |
| `test/firmware/110-cellular/app.zig` | 修改 | 追加 AT 引擎验证逻辑 |

**实现内容：**
- `AtStatus` 枚举（ok/error/cme_error/cms_error/timeout）
- `AtResponse` 结构体（status + lines + error_code + getLine/firstLine）
- `UrcHandler` 结构体（prefix + callback）
- `AtEngine` 结构体：
  - `init(io: Io) AtEngine`
  - `setIo(io: Io) void` — 运行时切换底层 Io（CMUX 切换时用）
  - `send(cmd, timeout_ms) AtResponse` — 发送指令并等待响应
  - `registerUrc(prefix, handler) bool` — 注册 URC 处理器
  - `unregisterUrc(prefix) void`
  - `pumpUrcs() void` — 轮询并分发 URC

**Mock 测试命令：**

```bash
zig test src/pkg/cellular/at.zig
```

**Mock 测试用例（11 个）：**

| ID | 测试名 | 验证内容 |
|----|--------|----------|
| AT-01 | basic OK | 发送 "AT\r" → MockIo 喂 "\r\nOK\r\n" → status=ok |
| AT-02 | response with data | 喂 "+CSQ: 20,0\r\nOK\r\n" → line 正确解析 |
| AT-03 | ERROR | 喂 "ERROR\r\n" → status=error |
| AT-04 | CME ERROR | 喂 "+CME ERROR: 10\r\n" → code=10 |
| AT-05 | timeout | 不喂任何数据 → status=timeout |
| AT-06 | URC idle | 注册 "+CRING" → 喂 URC → pumpUrcs → callback 被调用 |
| AT-07 | URC interleaved | 响应中夹杂 URC → 响应和 URC 都正确处理 |
| AT-08 | partial reassembly | 分两次喂 "O" 和 "K\r\n" → 拼装为完整响应 |
| AT-09 | multi-line | 4 行数据 + OK → 全部捕获 |
| AT-10 | setIo swap | Io A → 切换到 Io B → 数据走 B |
| AT-11 | multiple URCs | 注册 3 个前缀 → 各自正确分发 |

**烧录验证逻辑（追加到 app.zig）：**

```
1. 用 io.fromUart() 包装 UART 为 Io
2. 创建 AtEngine.init(io)
3. 依次发送以下指令，每条都 log 输出完整 AtResponse：

   指令 1: AT
   预期: status=ok, 无数据行
   [I] === Step 4: AT engine test ===
   [I] CMD: AT
   [I] RSP: status=ok, lines=0

   指令 2: ATI
   预期: status=ok, 数据行包含模组型号
   [I] CMD: ATI
   [I] RSP: status=ok, lines=N
   [I]   line[0]: Quectel
   [I]   line[1]: EC25
   [I]   line[2]: Revision: ...

   指令 3: AT+CSQ
   预期: status=ok, 数据行包含 "+CSQ: X,Y"
   [I] CMD: AT+CSQ
   [I] RSP: status=ok, lines=1
   [I]   line[0]: +CSQ: 20,0

   指令 4: AT+CPIN?
   预期: status=ok, 数据行包含 "+CPIN: READY"（或 SIM PIN）
   [I] CMD: AT+CPIN?
   [I] RSP: status=ok, lines=1
   [I]   line[0]: +CPIN: READY

   指令 5: AT+INVALID_CMD
   预期: status=error 或 cme_error
   [I] CMD: AT+INVALID_CMD
   [I] RSP: status=error
```

**通过标准：**
- 5 条指令全部返回预期的 status
- ATI 返回的型号与实际模组一致
- AT+CSQ 返回的信号值在合理范围（0-31 或 99）
- AT+CPIN? 返回与实际 SIM 卡状态一致
- 无超时、无乱码、无崩溃

**这是第一个核心里程碑：Zig AT 引擎在真实 4G 模组上完成了端到端指令交互。**

---

### Step 5: sim.zig — SIM 卡管理

**目标：** 实现 SIM 卡管理模块，在真机上读取真实 SIM 卡信息。

**验证方式：烧录验证**

**理由：** SIM 管理的每个函数都通过 AtEngine 发送 AT 指令到模组。
不同 SIM 卡的状态、IMSI、ICCID 格式可能不同，必须真机验证。

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/pkg/cellular/sim.zig` | 新建 | SIM 卡管理 |
| `test/firmware/110-cellular/app.zig` | 修改 | 追加 SIM 验证逻辑 |

**实现内容：**
- `Sim` 结构体：
  - `init(at_engine: *AtEngine) Sim`
  - `getStatus() !SimStatus` — 发送 AT+CPIN? 并解析
  - `getImsi() !SimInfo` — 发送 AT+CIMI 并解析
  - `getIccid() !SimInfo` — 发送 AT+QCCID 并解析
  - `enterPin(pin: []const u8) !void` — 发送 AT+CPIN=xxxx
  - `enableHotplug() !void` — 发送 AT+QSIMSTAT=1 启用热插拔通知
  - `registerUrcs(dispatch_ctx) void` — 注册 SIM 相关 URC 处理器

**Mock 测试命令：**

```bash
zig test src/pkg/cellular/sim.zig
```

**Mock 测试用例（7 个）：**

| ID | 测试名 | 验证内容 |
|----|--------|----------|
| SM-01 | SIM ready | MockIo 喂 "+CPIN: READY\r\nOK\r\n" → .ready |
| SM-02 | not inserted | 喂 "+CME ERROR: 10\r\n" → .not_inserted |
| SM-03 | PIN required | 喂 "+CPIN: SIM PIN\r\nOK\r\n" → .pin_required |
| SM-04 | IMSI | 喂 "460001234567890\r\nOK\r\n" → IMSI 正确 |
| SM-05 | ICCID | 喂 "+QCCID: 89860...\r\nOK\r\n" → ICCID 正确 |
| SM-06 | hotplug URC | 喂 "+QSIMSTAT: 0,0" → URC callback 触发 |
| SM-07 | PIN entry | 验证发送 "AT+CPIN=1234\r" → OK |

**烧录验证逻辑（追加到 app.zig）：**

```
1. 创建 Sim.init(&at_engine)
2. 调用 sim.getStatus()
   [I] === Step 5: SIM test ===
   [I] SIM status: ready

3. 调用 sim.getImsi()
   [I] IMSI: 460001234567890

4. 调用 sim.getIccid()
   [I] ICCID: 89860012345678901234

5. 如果 SIM 状态为 pin_required，额外测试：
   [I] SIM requires PIN, entering...
   sim.enterPin("1234")
   [I] PIN accepted
```

**通过标准：**
- SIM 状态与实际一致（有卡显示 ready，无卡显示 not_inserted）
- IMSI 为 15 位数字，前 3 位为 MCC（中国为 460）
- ICCID 为 19-20 位数字，前 2 位为 89
- 无崩溃、无解析错误

---

### Step 6: signal.zig — 信号质量查询

**目标：** 实现信号质量查询模块，在真机上读取真实信号数据。

**验证方式：烧录验证**

**理由：** 信号查询依赖真实的无线环境。CSQ 值、注册状态、网络类型
都必须在有 SIM 卡和信号的环境下验证。

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/pkg/cellular/signal.zig` | 新建 | 信号质量查询 |
| `test/firmware/110-cellular/app.zig` | 修改 | 追加信号查询验证逻辑 |

**实现内容：**
- `Signal` 结构体：
  - `init(at_engine: *AtEngine) Signal`
  - `getStrength() !SignalInfo` — 发送 AT+CSQ（及 AT+QCSQ）并解析
  - `getRegistration() !RegistrationStatus` — 发送 AT+CGREG? / AT+CEREG? 并解析
  - `getNetworkType() !NetworkType` — 发送 AT+QNWINFO 并解析

**Mock 测试命令：**

```bash
zig test src/pkg/cellular/signal.zig
```

**Mock 测试用例（7 个）：**

| ID | 测试名 | 验证内容 |
|----|--------|----------|
| SG-01 | CSQ | 喂 "+CSQ: 20,0\r\nOK\r\n" → rssi=-73 |
| SG-02 | no signal | 喂 "+CSQ: 99,99\r\nOK\r\n" → null |
| SG-03 | LTE quality | 喂 AT+QCSQ 响应 → rsrp/rsrq 正确 |
| SG-04 | reg home | 喂 "+CGREG: 0,1\r\nOK\r\n" → registered_home |
| SG-05 | reg roaming | 喂 "+CEREG: 0,5\r\nOK\r\n" → registered_roaming |
| SG-06 | reg denied | 喂 "+CGREG: 0,3\r\nOK\r\n" → denied |
| SG-07 | network type | 喂 AT+QNWINFO 响应 → .lte |

**烧录验证逻辑（追加到 app.zig）：**

```
1. 创建 Signal.init(&at_engine)

2. 调用 signal.getStrength()
   [I] === Step 6: Signal test ===
   [I] RSSI: -73 dBm (CSQ=20)
   [I] BER: 0

3. 调用 signal.getRegistration()
   [I] Registration: registered_home

4. 调用 signal.getNetworkType()
   [I] Network type: lte

5. 循环 5 次，每次间隔 2 秒，观察信号变化
   [I] Signal poll 1/5: rssi=-73, reg=registered_home, net=lte
   [I] Signal poll 2/5: rssi=-71, reg=registered_home, net=lte
   ...
```

**通过标准：**
- RSSI 在合理范围（-113 到 -51 dBm，或 99 表示无信号）
- 有 SIM 卡且有信号时，注册状态为 registered_home 或 registered_roaming
- 网络类型与运营商实际网络一致
- 循环查询无崩溃、无内存泄漏

---

### Step 7: modem.zig reducer — 状态机纯逻辑

**目标：** 实现 Modem 的 flux reducer（纯状态转换逻辑）。

**验证方式：Mock 验证 + 可选烧录验证**

**理由：** reducer 是纯函数：输入 (ModemState, ModemEvent) → 输出新 ModemState。
没有任何 IO 操作，Mock 即可完整覆盖。
但建议在真机上跑一遍状态转换序列，验证嵌入式环境下的内存布局、
对齐、tagged union dispatch 等行为与开发机一致。

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/pkg/cellular/modem.zig` | 新建（部分） | 先只实现 reduce 函数 + Store 集成 |

**实现内容：**
- `reduce(state: *ModemState, event: ModemEvent) void` — 纯状态转换函数
- `Store(ModemState, ModemEvent)` 集成（使用 `pkg/flux/store.zig`）
- 状态转换规则详见 plan.md 第 6 节 Reducer

**测试命令：**

```bash
zig test src/pkg/cellular/modem.zig
```

**测试用例（18 个）：**

| ID | 测试名 | 验证内容 |
|----|--------|----------|
| MR-01 | off → power_on → starting | 基本启动 |
| MR-02 | starting → at_ready → ready | error_count 重置为 0 |
| MR-03 | starting → at_timeout → error | error_count 递增 |
| MR-04 | ready → sim_ready → sim_ready | sim 状态更新为 .ready |
| MR-05 | ready → sim_error → error | sim 状态存储错误类型 |
| MR-06 | sim_ready → registered → registering | 注册状态存储 |
| MR-07 | sim_ready → reg_failed → error | 注册失败 |
| MR-08 | sim_ready → sim_removed → ready | SIM 拔出回退 |
| MR-09 | registering → dial_connected → connected | PPP 连接成功 |
| MR-10 | registering → dial_failed → error | PPP 连接失败 |
| MR-11 | connected → ip_lost → registering | 断线重连 |
| MR-12 | connected → sim_removed → ready | 在线时 SIM 拔出 |
| MR-13 | connected → signal_updated | 信号更新，phase 不变 |
| MR-14 | connected → stop → off | 正常关机 |
| MR-15 | error → error_recovery → starting | 错误恢复重试 |
| MR-16 | error → stop → off | 错误状态关机 |
| MR-17 | any phase → stop → off | 任意状态都能关机 |
| MR-18 | ignored events | 错误阶段的事件不改变状态 |

**通过标准：** `All 18 tests passed.`

**可选烧录验证（追加到 app.zig）：**

```
1. 在固件中创建 flux Store，手动 dispatch 完整事件序列：
   [I] === Step 7: Reducer real-device test ===

   dispatch(.power_on)
   [I] off -> power_on -> starting (ok)

   dispatch(.at_ready)
   [I] starting -> at_ready -> ready, error_count=0 (ok)

   dispatch(.sim_ready)
   [I] ready -> sim_ready -> sim_ready (ok)

   dispatch(.{ .registered = .registered_home })
   [I] sim_ready -> registered -> registering (ok)

   dispatch(.dial_connected)
   [I] registering -> dial_connected -> connected (ok)

   dispatch(.{ .signal_updated = .{ .rssi = -73, .ber = 0, ... } })
   [I] connected -> signal_updated -> connected, rssi=-73 (ok)

   dispatch(.ip_lost)
   [I] connected -> ip_lost -> registering (ok)

   dispatch(.stop)
   [I] registering -> stop -> off (ok)

   [I] Reducer test: 8/8 transitions correct
```

**可选烧录通过标准：** 所有状态转换与 Mock 测试结果一致，
tagged union 和结构体在 ESP32S3（Xtensa）上内存布局正常。

---

### Step 8: modem.zig 路由 — Modem 核心路由逻辑

**目标：** 实现 Modem 的 init / at() / pppIo() 路由逻辑，在真机上验证
通过 Modem 抽象层发送 AT 指令。

**验证方式：烧录验证**

**理由：** Modem 的路由逻辑决定了 AT 指令和 PPP 数据走哪个 Io。
必须在真机上验证 Modem.at().send() 能正确透传到模组。

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/pkg/cellular/modem.zig` | 修改 | 补充 init / at() / pppIo() / dispatch 等 |
| `test/firmware/110-cellular/app.zig` | 修改 | 追加 Modem 路由验证逻辑 |

**实现内容（在 Step 7 基础上追加）：**
- `InitConfig` 结构体（io / at_io / data_io / config）
- `Modem.init(cfg: InitConfig) Modem` — 根据参数自动选择 single/multi 模式
- `Modem.deinit()`
- `Modem.at() *AtEngine` — 返回 AT 引擎引用
- `Modem.pppIo() ?Io` — 返回 PPP 数据通道
- `Modem.dispatch(event)` / `getState()` / `isDirty()` / `commitFrame()`
- 模式判断逻辑：data_io != null → multi-channel，否则 single-channel

**Mock 测试用例（13 个，此步先跑不涉及 CMUX 的子集）：**

| ID | 测试名 | 验证内容 |
|----|--------|----------|
| MD-01 | single-ch init | .io 提供 → mode = single_channel |
| MD-02 | multi-ch init | .at_io + .data_io → mode = multi_channel |
| MD-03 | invalid init | 都不提供 → 返回错误 |
| MD-04 | single-ch AT | at().send("AT") → 字节出现在 raw Io 上 |
| MD-05 | multi-ch AT | at().send("AT") → 字节只出现在 at_io 上 |
| MD-06 | multi-ch PPP | pppIo().write → 字节只出现在 data_io 上 |
| MD-07 | multi-ch pppIo available | pppIo() != null（初始化后立即可用） |
| MD-12 | multi-ch enterCmux noop | enterCmux() 在 multi-ch 模式下为 no-op |
| MD-13 | enterDataMode | ATD*99# → CONNECT → pppIo 激活 |

> 注：MD-08 ~ MD-11 涉及 CMUX，在 Step 10 中验证。

**烧录验证逻辑（追加到 app.zig）：**

```
1. 用 Modem.init(.{ .io = uart_io }) 创建 Modem（single-channel 模式）
2. 通过 modem.at() 获取 AtEngine
3. 发送 AT 指令验证路由正确性：

   [I] === Step 8: Modem routing test ===
   [I] Modem mode: single_channel
   [I] modem.at().send("AT") -> status=ok
   [I] modem.at().send("ATI") -> Quectel EC25 ...
   [I] modem.pppIo() = null (CMUX not active yet, expected)

4. 验证 dispatch + getState：
   modem.dispatch(.power_on)
   [I] State after power_on: phase=starting
   modem.dispatch(.at_ready)
   [I] State after at_ready: phase=ready
```

**通过标准：**
- Modem.init() 成功，mode = single_channel
- modem.at().send("AT") 返回 ok（证明路由到了正确的 Io）
- modem.pppIo() 返回 null（CMUX 未激活，符合预期）
- dispatch 后状态转换正确

---

### Step 9: cmux.zig — CMUX 帧编解码（核心里程碑 #2）

**目标：** 实现 GSM 07.10 CMUX 协议，在真机上完成 CMUX 协商和虚拟通道通信。

**验证方式：烧录验证**

**理由：** CMUX 协议的正确性高度依赖真实模组的实现。不同模组对 CMUX 的支持
细节可能不同（帧长度、FCS 计算、SABM/UA 时序等）。必须真机验证。

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/pkg/cellular/cmux.zig` | 新建 | CMUX 帧编解码 + 虚拟通道复用 |
| `test/firmware/110-cellular/app.zig` | 修改 | 追加 CMUX 验证逻辑 |

**实现内容：**
- `Frame` 结构体（dlci / control / data）
- `Cmux(comptime max_channels)` 泛型结构体：
  - `init(io: Io) @This()` — 绑定底层单通道 Io
  - `open(dlcis: []const u8) !void` — 发送 AT+CMUX=0，然后 SABM/UA 握手
  - `close() void` — 发送 DISC 帧关闭所有通道
  - `channelIo(dlci: u8) ?Io` — 获取指定 DLCI 的虚拟通道 Io
  - `pump() void` — 从底层 Io 读取数据，解帧，分发到对应通道缓冲区
  - `encodeFrame(frame, out) usize` — 编码 GSM 07.10 帧
  - `decodeFrame(data) ?Frame` — 解码 GSM 07.10 帧
  - `calcFcs(data) u8` — 计算 FCS 校验

**Mock 测试命令：**

```bash
zig test src/pkg/cellular/cmux.zig
```

**Mock 测试用例（10 个）：**

| ID | 测试名 | 验证内容 |
|----|--------|----------|
| MX-01 | UIH encode | 数据 → 正确的 GSM 07.10 字节序列 |
| MX-02 | UIH decode | 原始字节 → Frame { dlci, payload } |
| MX-03 | SABM/UA handshake | open() → SABM 发出 → 喂 UA → 成功 |
| MX-04 | channel write | channelIo(2).write("AT") → UIH DLCI=2 帧 |
| MX-05 | channel read | 喂 UIH DLCI=2 帧 → channelIo(2).read() → 数据 |
| MX-06 | channel isolation | DLCI 1 的数据不出现在 DLCI 2 |
| MX-07 | DISC/close | close() → DISC 帧发出 |
| MX-08 | FCS | 已知 GSM 07.10 测试向量 |
| MX-09 | concurrent | 交错的 DLCI 1+2 帧 → 正确复用 |
| MX-10 | pump demux | 混合帧 → 正确分发到各通道缓冲区 |

**烧录验证逻辑（追加到 app.zig）：**

```
1. 先通过 AT 引擎确认模组就绪：
   at_engine.send("AT") -> OK

2. 创建 CMUX 并协商：
   var cmux = Cmux(4).init(uart_io);
   cmux.open(&.{1, 2})
   [I] === Step 9: CMUX test ===
   [I] Sending AT+CMUX=0...
   [I] AT+CMUX=0 -> OK
   [I] SABM DLCI 0 sent, waiting UA...
   [I] UA DLCI 0 received
   [I] SABM DLCI 1 sent, waiting UA...
   [I] UA DLCI 1 received
   [I] SABM DLCI 2 sent, waiting UA...
   [I] UA DLCI 2 received
   [I] CMUX active, 2 channels open

3. 通过 CMUX 虚拟通道发送 AT 指令：
   const at_ch = cmux.channelIo(2);  // AT 通道
   at_ch.write("AT\r")
   cmux.pump()  // 读取底层 Io，解帧分发
   at_ch.read(buf)
   [I] CMUX ch2 AT -> response: OK

4. 通过 CMUX 虚拟通道查询信号：
   at_ch.write("AT+CSQ\r")
   cmux.pump()
   at_ch.read(buf)
   [I] CMUX ch2 AT+CSQ -> response: +CSQ: 20,0

5. 关闭 CMUX：
   cmux.close()
   [I] CMUX closed, DISC frames sent

6. 恢复直连 AT 验证模组仍然正常：
   -- 等待模组退出 CMUX 模式
   at_engine.send("AT") -> OK
   [I] Post-CMUX AT -> OK (modem recovered)
```

**通过标准：**
- AT+CMUX=0 返回 OK
- 所有 DLCI 的 SABM/UA 握手成功
- 通过 CMUX 虚拟通道发送 AT 指令能收到正确响应
- CMUX 关闭后模组能恢复到正常 AT 模式
- 无帧错误、无 FCS 校验失败、无超时

**这是第二个核心里程碑：CMUX 在真实模组上跑通，虚拟通道可用。**

---

### Step 10: modem.zig 完整 — 全链路验证（最终里程碑）

**目标：** 补全 Modem 的 CMUX 管理逻辑，实现完整的单通道模式全链路。

**验证方式：烧录验证**

**理由：** 这是所有组件的集成验证。Modem 在单通道模式下自动管理 CMUX，
通过 modem.at() 和 modem.pppIo() 对外暴露独立的 AT 和 PPP 通道。
必须在真机上验证完整流程。

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/pkg/cellular/modem.zig` | 修改 | 补全 enterCmux/exitCmux/pump |
| `src/mod.zig` | 修改 | 添加 pkg.cellular 导出 |
| `test/firmware/110-cellular/app.zig` | 修改 | 全链路验证逻辑 |

**补全的实现内容：**
- `Modem.enterCmux() !void` — 单通道：AT+CMUX=0 + SABM/UA + Io 切换
- `Modem.exitCmux() void` — 单通道：DISC + 恢复原始 Io
- `Modem.isCmuxActive() bool`
- `Modem.pump() void` — 单通道 + CMUX：调用 cmux.pump() 解帧分发
- `Modem.enterDataMode() !void` — ATD*99# → CONNECT
- `Modem.exitDataMode() void` — +++ / ATH

**补全的 Mock 测试用例（之前跳过的 4 个）：**

| ID | 测试名 | 验证内容 |
|----|--------|----------|
| MD-08 | single-ch enterCmux | AT+CMUX=0 发出，SABM/UA，Io 切换 |
| MD-09 | single-ch CMUX AT | CMUX 后 at().send → CMUX DLCI 2 |
| MD-10 | single-ch CMUX PPP | CMUX 后 pppIo() → CMUX DLCI 1 |
| MD-11 | single-ch exitCmux | DISC 发出，AT 恢复到 raw Io |

**烧录验证逻辑（完整流程）：**

```
[I] ========================================
[I] Step 10: Full Modem integration test
[I] ========================================

Phase 1: 初始化
   var modem = Modem.init(.{ .io = uart_io });
   [I] Modem initialized: mode=single_channel, phase=off

Phase 2: 直连 AT（CMUX 前）
   modem.dispatch(.power_on);
   const r1 = modem.at().send("AT", 5000);
   [I] Direct AT -> status=ok
   modem.dispatch(.at_ready);
   [I] State: phase=ready

Phase 3: SIM 检查
   var sim = Sim.init(modem.at());
   const sim_status = sim.getStatus();
   [I] SIM: ready
   modem.dispatch(.sim_ready);
   [I] State: phase=sim_ready

Phase 4: 信号检查
   var sig = Signal.init(modem.at());
   const strength = sig.getStrength();
   [I] Signal: rssi=-73, network=lte
   const reg = sig.getRegistration();
   [I] Registration: registered_home
   modem.dispatch(.{ .registered = reg });
   [I] State: phase=registering

Phase 5: 进入 CMUX
   modem.enterCmux();
   [I] CMUX negotiated, channels open
   [I] modem.isCmuxActive() = true

Phase 6: 通过 CMUX AT 通道验证
   const r2 = modem.at().send("AT+CSQ", 5000);
   [I] CMUX AT channel -> +CSQ: 20,0

Phase 7: PPP 通道就绪
   const ppp = modem.pppIo();
   [I] PPP Io available: true
   -- 注意：此处不实际拨号，只验证通道存在
   -- 实际 PPP 拨号由 lwIP 层负责

Phase 8: 退出 CMUX
   modem.exitCmux();
   [I] CMUX closed
   [I] modem.isCmuxActive() = false

Phase 9: 恢复直连 AT
   const r3 = modem.at().send("AT", 5000);
   [I] Post-CMUX direct AT -> status=ok

Phase 10: 关机
   modem.dispatch(.stop);
   [I] State: phase=off

[I] ========================================
[I] ALL TESTS PASSED
[I] ========================================
```

**通过标准：**
- 10 个 Phase 全部成功执行，无崩溃
- 直连 AT → CMUX AT → 退出 CMUX → 直连 AT 全链路通畅
- 状态机转换与预期一致（off → starting → ready → sim_ready → registering）
- PPP Io 在 CMUX 激活后可用
- 串口 log 最终输出 "ALL TESTS PASSED"

**这是最终里程碑：完整的 Modem 抽象在 ESP32S3 + 真实 4G 模组上全链路跑通。**

---

### Step 11: mod.zig 导出 + 收尾

**目标：** 将 cellular 包注册到项目模块树，确保 `zig test` 和 `zig build` 都能编译通过。

**验证方式：Mock 验证（编译检查）**

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/mod.zig` | 修改 | 在 pkg 下添加 cellular 导出 |

**验证命令：**

```bash
zig test src/mod.zig          # 全量编译检查
zig test src/pkg/cellular/types.zig
zig test src/pkg/cellular/io.zig
zig test src/pkg/cellular/at_parse.zig
zig test src/pkg/cellular/at.zig
zig test src/pkg/cellular/cmux.zig
zig test src/pkg/cellular/modem.zig
zig test src/pkg/cellular/sim.zig
zig test src/pkg/cellular/signal.zig
```

**通过标准：** 所有 83 个测试通过，无编译错误。

---

### 总览表

| Step | 文件 | 验证方式 | Mock 测试数 | 烧录验证重点 | 里程碑 |
|------|------|----------|------------|-------------|--------|
| 0 | 基础设施 | **烧录** | 0 | UART 原始字节收发 | |
| 1 | types.zig | Mock | 3 | — | |
| 2 | io.zig | **烧录** | 3 | Io 透传 UART 到模组 | |
| 3 | at_parse.zig | Mock + **可选烧录** | 11 | 用真实模组响应验证解析兼容性 | |
| 4 | at.zig | **烧录** | 11 | AT 引擎端到端 | **里程碑 #1** |
| 5 | sim.zig | **烧录** | 7 | 真实 SIM 信息读取 | |
| 6 | signal.zig | **烧录** | 7 | 真实信号查询 | |
| 7 | modem reducer | Mock + **可选烧录** | 18 | 验证嵌入式环境下内存布局和状态转换 | |
| 8 | modem 路由 | **烧录** | 13 | Modem 抽象层 AT 透传 | |
| 9 | cmux.zig | **烧录** | 10 | CMUX 真机协商 | **里程碑 #2** |
| 10 | modem 完整 | **烧录** | — | 全链路 CMUX+AT+PPP | **最终里程碑** |
| 11 | mod.zig 导出 | Mock | 0 | — | |

**总计：83 个 Mock 测试 + 7 次必须烧录验证 + 2 次可选烧录验证**

### Phase 2（可选，后续扩展）

| 文件 | 说明 |
|------|------|
| voice.zig | 语音通话管理（dial/answer/hangup） |
| apn.zig | APN 自动解析（根据 IMSI 匹配运营商） |

Phase 2 在 Phase 1 全部完成并验证后再开始。

---

## 10. Discussion Log

### R1-R2: Initial analysis, planning principles
### R3: NO HAL contract, all in pkg, platform boundary = UART
### R4: PPP delegated to lwIP
### R5: Modem as opaque router, CMUX internal
### R6-R7: WiFi state analysis (pollEvent, not flux)
### R8: Modem uses flux pattern (Event -> reducer -> State)
### R9-R10: State named `connected`
### R11-R12: 7-phase ModemState
### R13: Directory tree and file specs
### R14: modem.zig in pkg, not hal
### R15: Package named `cellular`, type named `Modem`
### R16: Modem accepts Io, not UART. Supports UART/USB/SPI

### R19 (2026-03-12)

**Topic:** 详细开发计划（Step-by-Step）

1. 制定了 12 步（Step 0 ~ Step 11）的详细开发计划
2. 明确验证原则：能烧录验证就烧录验证，只有纯计算逻辑才用 Mock
3. 分类结果：7 步烧录验证，3 步 Mock 验证，1 步编译检查，1 步基础设施
4. 每一步都详细描述了：涉及文件、实现内容、测试用例、烧录验证逻辑、通过标准
5. 定义了 3 个里程碑：AT 引擎端到端（Step 4）、CMUX 真机协商（Step 9）、全链路（Step 10）
6. 所有烧录验证共用一个递增式固件工程 test/firmware/110-cellular/
7. 替换了原来简略的 Phase 1/Phase 2 分段

### R18 (2026-03-12)

**Topic:** USB 端口细节 & Io 抽象策略记录

1. Quectel 模组 USB 连接时暴露 4 个虚拟串口：DM / NMEA / AT / PPP
2. USB 天然多通道，无需 CMUX；UART/SPI 单通道需要 CMUX
3. Io 是唯一的跨平台边界，上层 pkg/cellular 全部纯 Zig
4. Mac/Linux 可通过 USB 接真机进行 zig test 集成测试
5. 在 3.1 节补充了 Io 抽象策略说明、USB 端口映射表、真机测试支持说明

### R17 (2026-03-12)

**Topic:** Full architecture review after R16 transport abstraction.

**Changes from R13:**

1. Modem.init() redesigned:
   - Old: `Modem(UartType)` -- comptime parameterized on UART type
   - New: `Modem.init(InitConfig)` -- runtime config with Io instances
   - InitConfig has two modes:
     .io = single Io (UART/SPI) -> single-channel, CMUX used
     .at_io + .data_io = two Io (USB) -> multi-channel, no CMUX

2. Modem auto-detects mode:
   - data_io provided -> multi-channel, CMUX skipped entirely
   - data_io null -> single-channel, CMUX used when needed

3. enterCmux/exitCmux behavior changes:
   - Multi-channel mode: no-op (channels already separated)
   - Single-channel mode: actual CMUX negotiation

4. pppIo() availability:
   - Multi-channel: available immediately (data_io passed at init)
   - Single-channel: available after enterCmux()

5. pump() behavior:
   - Multi-channel: no-op
   - Single-channel + CMUX: demuxes incoming bytes

6. ModemConfig simplified:
   - Removed cmux_enabled (auto-detected from init params)
   - Removed baud_rate (transport-level concern, not Modem's)
   - Kept cmux_channels and cmux_baud_rate (for single-channel mode)

7. io.zig updated:
   - Added fromSpi() helper
   - Added fromBufferPair() for testing
   - Removed UART-specific assumptions

8. Test plan updated:
   - MockIo replaces MockUart as universal test transport
   - Added multi-channel mode tests (MD-02, MD-05, MD-06, MD-07, MD-12)
   - Added init validation test (MD-03)
   - Total: 83 tests (was 78)

9. Usage examples added for ESP32/Linux/Test scenarios

---

## 11. Open Questions

### 原有问题

- [ ] Q1: uart.zig: need setBaudrate() for CMUX baud ramp in single-channel mode?
- [ ] Q2: Thread safety: should Modem.dispatch() be thread-safe?
- [ ] Q3: Should modem.zig depend on pkg/flux/store.zig or embed minimal store?
- [ ] Q4: pump() in single-channel mode: caller responsibility or internal thread?
- [ ] Q5: Package name: `cellular` confirmed? (R15 analysis done, pending user confirm)

### R20 Review 发现的问题

**关键遗漏（阻塞开发）：**

- [ ] Q6: Io 接口缺少 poll/非阻塞语义定义。当前 Io 只有 read/write，但 HAL uart.zig 有 poll(flags, timeout_ms)。AtEngine.send(timeout_ms) 的超时如何实现？Io.read() 是阻塞还是非阻塞？如果非阻塞（WouldBlock），AT 引擎需要时间源做轮询；如果阻塞，timeout_ms 参数就是摆设。
- [ ] Q7: 缺少电源管理接口。几乎所有 Quectel 模组需要 POWER_KEY 脉冲开机、RESET 引脚复位。Modem 没有 powerOn()/powerOff()/reset()。状态机有 power_on 事件但无对应硬件操作。error_recovery 时如何硬件复位？建议增加 PowerControl 回调接口。
- [ ] Q8: Io 接口缺少 close/flush。USB 串口需要 close fd；UART 切换 CMUX 前可能需要 flush 等待发送完成。
- [ ] Q9: CMUX open() 职责矛盾。文档说 open() 负责"发送 AT+CMUX=0 + SABM/UA 握手"，但 Cmux 只持有 Io 不持有 AtEngine。AT+CMUX=0 应由谁发送？Step 9 烧录验证流程暗示由 Modem.enterCmux() 通过 AtEngine 发送，但 cmux.zig 接口定义暗示由 Cmux.open() 自己发送。需要明确。
- [ ] Q10: PPP/lwIP 集成接口完全缺失。从 enterDataMode(ATD*99#) 到 lwIP 接管之间：拨号前需要 AT+CGDCONT 设置 APN；CONNECT 后字节流是 PPP LCP 帧；lwIP pppos_create 需要 output_cb 如何与 pppIo() 对接？这是 Phase 1 联网的核心路径。

**设计深度不足：**

- [ ] Q11: registering 阶段命名语义反转。收到 registered 事件后进入 registering 阶段，语义矛盾。实际含义是"已注册网络，等待 PPP 拨号"。建议改名为 registered 或 dialing。
- [ ] Q12: AtResponse 缓冲区硬编码 [8][128]u8。ATI 响应可能超 8 行；AT+COPS=? 单行可能超 128 字节。缺少溢出处理策略。
- [ ] Q13: 错误恢复策略缺失。谁触发 error_recovery？自动还是外部？重试间隔？最大次数？error_count 只递增无上限。不同错误类型恢复策略应不同。
- [ ] Q14: URC pump 调度策略未定义。单通道 CMUX 模式下 pump() 不够频繁会导致缓冲区溢出。AtEngine.pumpUrcs() 和 Cmux.pump() 的调用顺序和频率未定义。
- [ ] Q15: MockIo.onSend() 自动应答器设计模糊。支持几个 trigger-response 对？精确匹配还是前缀？同一 trigger 需要不同响应（第一次 ERROR 第二次 OK）怎么办？
- [ ] Q16: sim.zig registerUrcs(dispatch_ctx: anytype) 的 anytype 是 comptime 参数，但 URC 回调是运行时注册的，签名可能有实现问题。

**过度设计：**

- [ ] Q17: voice.zig 是否应从 Phase 2 移除？嵌入式 4G 语音通话极罕见（需音频编解码、PCM 通道）。
- [ ] Q18: fromSpi() 是否降级为按需添加？SPI 接 4G 模组实际产品中极少，无测试覆盖。
- [ ] Q19: Cmux comptime max_channels 泛型是否简化？实际通道数固定 2-3 个，泛型增加复杂度收益低。
- [ ] Q20: ChannelConfig/ChannelRole 可配置性是否过度？Quectel DLCI 分配基本固定，用户配置增加出错概率。

**可行性风险：**

- [ ] Q21: CMUX 实现复杂度可能被低估。GSM 07.10 Basic 模式的帧同步、流控、错误恢复比文档描述复杂。10 个测试可能不够。
- [ ] Q22: 内存使用评估缺失。CMUX 每通道独立缓冲区 + AT 引擎缓冲区，ESP32 总 RAM 占用需评估。

---

## 12. Discussion: Q6 — Io poll/超时语义

### 问题

AtEngine.send(cmd, timeout_ms) 需要在等待模组响应时实现超时。当前 Io 只有 read/write，无法实现。

HAL uart.zig 已有 poll(flags, timeout_ms) 方法，但 Io 接口丢掉了这个能力。

影响范围：AtEngine.send()、AtEngine.pumpUrcs()、Cmux.pump()、SABM/UA 握手 — 所有需要"等待数据或超时"的场景。

### 方案 A：给 Io 加 pollFn

```
Io = struct {
    ctx: *anyopaque,
    readFn:  *const fn (*anyopaque, []u8) IoError!usize,
    writeFn: *const fn (*anyopaque, []const u8) IoError!usize,
    pollFn:  *const fn (*anyopaque, bool, bool, i32) PollResult,
};
```

- 优点：和 HAL uart.zig 对齐，fromUart() 直接透传 poll
- 缺点：USB 虚拟串口在 Linux/Mac 上需要用 POSIX poll()/select() 实现，每个平台都要适配
- 缺点：MockIo 也需要实现 poll 语义

### 方案 B：Io.read() 约定非阻塞 + AtEngine 接收时间源

```
AtEngine = struct {
    io: Io,
    nowFn: *const fn () u64,   // 毫秒时间源
};
```

- AT 引擎内部忙等循环：read() -> WouldBlock -> 检查 nowFn() 是否超时 -> 再 read()
- 优点：Io 接口保持最简，只需 read/write
- 缺点：忙等浪费 CPU，嵌入式上不可接受

### 方案 C：Io.read() 约定非阻塞 + AtEngine 接收 wait + 时间源

```
AtEngine = struct {
    io: Io,
    nowFn:  *const fn () u64,       // 毫秒时间源
    waitFn: *const fn (u32) void,   // sleep/yield ms
};
```

- AT 引擎：read() -> WouldBlock -> waitFn(10) -> 检查超时 -> 再 read()
- 优点：Io 保持最简；waitFn 让出 CPU 避免忙等
- 缺点：AtEngine 依赖变多（3 个外部注入）；wait 粒度影响响应延迟

### 方案 D：给 Io 加可选 pollFn

```
Io = struct {
    ctx: *anyopaque,
    readFn:  *const fn (*anyopaque, []u8) IoError!usize,
    writeFn: *const fn (*anyopaque, []const u8) IoError!usize,
    pollFn:  ?*const fn (*anyopaque, i32) PollFlags = null,
};
```

- 有 pollFn 时用 poll（高效阻塞等待）
- 无 pollFn 时退化为非阻塞 read + 需要外部时间源
- 优点：灵活，UART 平台高效，简单平台也能用
- 缺点：AtEngine 内部需要两条代码路径；可选字段增加接口复杂度

### 待决定

- Io.read() 的语义约定：阻塞 vs 非阻塞（WouldBlock）
- poll 能力放在 Io 里还是 AtEngine 里
- 时间源如何注入
