# 4G Cellular Module Plan

> Status: DISCUSSING — Q10 blocked on main branch IO/lwIP refactoring | Last updated: 2026-03-19 Round 45

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
| R12 | CellularPhase: **-ing 中间态**（probing/at_configuring/checking_sim/registering/dialing/disconnecting）+ registered/connected/error；详见 R44 |
| R14 | modem.zig belongs in pkg, not hal |
| R15 | Package named `cellular`, core type named `Modem` |
| R16 | Modem accepts generic Io, not UART. Supports UART/USB/SPI via Io abstraction |
| R21 | Io.pollFn required (not optional). read() non-blocking (WouldBlock). CMUX pump driven by independent thread. Time/Thread/Notify via comptime generics (aligned with existing pkg style). Io remains type-erased (runtime swap) |
| R22 | ~~PowerControl is optional callbacks~~ → **R38 修正**：PowerControl 改为 `comptime Gpio` 注入（与 hal/gpio.zig 的 `from(spec)` + `is()` 模式一致）。Modem 签名加 `comptime Gpio: type`，PowerPins 定义 power_pin/reset_pin/vint_pin 可选 pin 编号。set_rate 保持运行时回调（hal/uart 无此方法）。CONTEXT_ID 加入 ModemConfig 作为 `u8` 字段 |
| R23 | Q10 (PPP/lwIP) deferred — main branch will refactor unified Io poll + add pkg/lwip userspace netstack + netlink abstraction. WiFi HAL also has no lwIP integration (same pattern). Cellular aligns: provide pppIo()/netlink, lwIP handled externally |
| R24 | Synced main branch updates. Test files moved to test/unit/pkg/cellular/, test commands updated to `cd test/unit && zig build test`. Q10 still blocked. R36: main 已改为 Bus(in/out spec, ChannelFactory) + Injector，无 selector；Cellular 对齐为持 Injector 推事件。 |
| R25 | Split Modem (hardware driver) from Cellular (event source + state machine). Modem owns Io/CMUX/AtEngine only, no flux Store. Cellular owns Modem + EventInjector(CellularPayload), drives state machine in worker thread, pushes events via injector.invoke(payload) for Bus integration. Aligned with Button/MotionPeripheral pattern (R36: injector-based) |
| R26 | Subdirectory structure for pkg/cellular: `io/` (transport), `at/` (AT protocol), `modem/` (hardware driver). Shared types.zig and cellular.zig at root. Aligned with pkg/ble directory pattern (host/hci, host/l2cap, gatt, etc.) |
| R27 | ~~旧~~ 见 R44：`registered`（可拨号）与 `dialing`（拨号中）分离；`dial_failed` 回 `registered` |
| R28 | AT command type abstraction: each AT command is a Zig struct with comptime Response type, prefix, timeout, write/parse methods. AtEngine gains generic `send(comptime Cmd, cmd)` returning typed result. Inspired by Rust atat crate. Commands defined in `at/commands.zig`. sim.zig/signal.zig simplified to call typed commands |
| R29 | TraceIo Decorator in `io/trace.zig`: wraps any Io, logs all read/write bytes via user-provided log function. Zero-intrusion debugging (inspired by warthog618/modem trace package). URC type abstraction in `at/urcs.zig`: each URC is a struct with prefix + parse method, unified with R28 command type pattern (inspired by ublox-cellular-rs typed Urc enum) |
| R30 | Q13: 错误恢复简化。移除 ModemState.error_count。`retry` 由应用 dispatch；reducer：`error` + `retry` → `probing`，清空 `error_reason` 与 `at_timeout_count`。与 flux/app 等包一致，无自动重试 |
| R31 | ResponseMatcher + ModuleProfile 简化：ResponseMatcher 合并为 Command struct 的可选 `match` 方法（`@hasDecl` 检测），不引入独立类型。ModuleProfile 用命名空间文件替代（`modem/profiles/quectel.zig`、`modem/profiles/simcom.zig`），每个文件导出该模块专属的 commands/urcs/init sequence，Modem 层通过 `comptime Module` 泛型参数选择 |
| R32 | Q2: Modem 不做线程安全。依据：MotionPeripheral/Button 的 sensor/gpio 仅由 worker 线程访问，主线程只通过 Bus.recv() 收事件；BLE Host 的 HCI 仅由 readLoop/writeLoop 使用。Cellular 的 Modem 同理，仅 worker 访问，单线程使用即可 |
| R33 | Q25: enterCmux 时机与失败处理。参考 quectel C：在 **SIM ready 后**（对应 Zig：`registering` 已可发 CEREG 前后，或 `registered` 后）进入 CMUX。失败则 phase=error；应用 retry。CMUX 内部可降级波特率或恢复 UART |
| R34 | commands.zig 按 3GPP 标准分 13 类注释：General, Control, SIM/DeviceLock, MobileControl, NetworkService, PDP/Packet, CallControl, SMS, CMUX, TCP/IP, HTTP/MQTT/FTP, GNSS, Power/Sleep。核心状态机用到的命令给出完整实现，其余类别只留注释和关键命令列表，由 module profile 或专用文件按需实现 |
| R35 | 错误与重试融入状态机：统一 ModemError 类型；ModemState 增加 error_reason、at_timeout_count；只有达到重试次数或超时后才进 error 并向 Flux 抛 CellularEvent.error。tick() 只推断并 dispatch 事件，阈值与计数逻辑全部在 reducer 内（见 6.1） |
| R36 | 与 main 分支 Bus 架构对齐：Cellular 不再持有 Channel，改为在 init 时接收 `EventInjector(CellularPayload)`（由应用通过 `rt.bus.Injector(.cellular)` 传入）；发事件时调用 `injector.invoke(payload)`。应用 App 的 InputSpec 需包含 `.cellular = CellularPayload`；主循环用 `rt.recv()` 收事件再 `rt.dispatch()`，不再使用 selector.poll() 或 bus.register(channel)。Runtime 引用使用 `runtime/channel_factory`、`runtime/sync/notify`（及按需 mutex/condition）。 |
| R37 | Control 分离（Phase 1）：参考 pkg/ble/host 的「用户 API 入队 + 内部 loop 独占 transport」模式。Cellular 在 Phase 1 即提供 CellularControl handle：用户通过 control.getSignalQuality(timeout_ms)、control.send(Cmd, timeout_ms) 等发起请求，请求经 request_queue 交给 worker 在 tick 间隙执行，结果经 response channel 回传给调用方。**硬性约束**：用户请求的 timeout/失败仅作为该次请求的返回值（如 Err(Timeout)），**绝不**送入 reducer、不增加 at_timeout_count、不改变 phase。详见 5.8.1、6.1.1。 |
| R38 | PowerControl 修正：R22 的函数指针方案改为 `comptime Gpio` 注入。项目已有完整 HAL trait 抽象（`hal/gpio.zig` 的 `from(spec)` + `is()` 模式），PowerControl 应对齐此模式。Modem 签名加 `comptime Gpio: type`，编译期校验 `hal.gpio.is(Gpio)`。PowerPins 定义 power_pin/reset_pin/vint_pin 三个可选 `?u8` pin 编号，通过注入的 Gpio 实例操作。set_rate 保持运行时回调（hal/uart 合约无此方法，且仅 CMUX 初始化用一次）。CONTEXT_ID 加入 ModemConfig 作为 `context_id: u8 = 1`。apn_lookup 保持 phase 2，作为 Module 命名空间可选导出 |
| R39 | 实施约束：cellular 功能独立于 main，runtime 等依赖 main 最新版；有真机时须通过真机验证才能进入下一步，不得跳过烧录验证 |
| R40 | Q12 解决：AtResponse 缓冲区从 `[8][128]u8` 改为单一平坦缓冲区 `[buf_size]u8`，大小由 `comptime buf_size` 参数控制（参考 atat 的 const generic 模式）。AtResponse.body 为指向 rx_buf 内的切片，通过 lineIterator 按需遍历行。溢出返回 `AtStatus.overflow`。默认 1024；AT+COPS=?/AT+CMGL 等长响应需 2048+。AtEngine 签名变为 `AtEngine(comptime Time, comptime buf_size)`，Modem/Cellular 签名透传 `at_buf_size` |
| R41 | Q20 解决：保留 CMUX 通道可配置。理由：GSM 07.10 各 DLCI 由模组/用户约定，不同模组或固件可能分配不同（如 AT 在 DLCI 1、PPP 在 2，或反之）；用户需能通过 ModemConfig.cmux_channels 指定 DLCI 与 role（.at / .ppp）的对应关系。实现：enterCmux 的 DLCI 列表与 at/ppp 绑定均来自 config.cmux_channels；init 时做合法性校验。详见 5.6.1 可配置通道实施规格。 |
| R42 | tick() 改为按 phase 单条 AT 模式 + Q15 修正移除 onSend()。对比 quectel C / ublox-rs / Zephyr，业界主流是"每个状态只做一件事"而非"每次 tick 全量轮询"。tick() 内 switch(phase) 每次最多发一条 AT，状态转换靠单条 AT 结果 + URC 驱动。MockIo 移除 `onSend()` 自动应答，与 BLE `MockHci` 对齐只保留 FIFO `feed()` + `feedSequence()`。每次 tick 只发一条 AT，纯 FIFO 即可覆盖所有测试场景 |
| R43 | AtEngine：`send`/`sendRaw`、`LineIterator`、`pumpUrcs`、解析与命令侧扩展；`types_test.zig` 覆盖蜂窝类型与事件；`engine_test.zig` 大量用例。根目录 `zig build test-cellular`（及 test/unit 域步骤）跑蜂窝子集 UT；TLS stress 小修。 |
| R44 | **Phase = 进行中，Event = 一步结束**（唯一命名来源：`types.zig` + `cellular.zig`）。`CellularPhase`：`off`→`probing`→`at_configuring`→`checking_sim`→`registering`（驻网前反复 `AT+CEREG?`）→`registered`→`dialing`→`connected`；`disconnecting` 预留。`ModemEvent`：bootstrap 三步、`sim_status_reported`、`network_registration`；意图 `power_on`/`dial_requested`/`retry`/`stop`/`power_off`；数据 `dial_succeeded`/`dial_failed`/`ip_obtained`/`ip_lost`/`signal_updated`；失败 `bootstrap_at_error`/`at_timeout`。已弃用旧名：`at_ready`、`sim_ready`、`dial_start`、`dial_connected`、`registration_failed`（事件）。**验证**：`zig build test-cellular`。 |
| R45 | **实现**：`Store(CellularFsmState, ModemEvent)` + `cellularReduce`；`tick()` 只发 AT 并 `dispatch` 上述事件；`emitDiff` → `CellularPayload`。 |

**进度（2026-03-19）：** Step 8 modem 路由已完成：无效 init 报错、multi 下 pppIo()、mode()、MD-01～07/MD-12 UT、110-cellular Step 8 段落 + 真机烧录验证。下一步：Step 9 CMUX（见 § Step 9）。

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
  - 测试：通过 `MockIo`（两段线性 buffer）模拟任意通道

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

### 3.3 Modem vs Cellular — 两层拆分

| 层 | 类型 | 职责 | 类比 |
|----|------|------|------|
| **Modem** | 硬件驱动 | 拥有 Io/CMUX/AtEngine，知道怎么和 4G 模组对话 | hal/wifi.zig 的 WiFi 驱动 |
| **Cellular** | 事件源 | 拥有 Modem + EventInjector(CellularPayload)，在独立线程中驱动状态机，通过 `injector.invoke(payload)` 将状态变化推入 Bus | event/motion/peripheral.zig 的 MotionPeripheral |

**Modem 不持有状态机，不持有 flux Store。** Modem 是纯驱动层，只提供：
- `.at()` — AT 引擎
- `.pppIo()` — PPP 数据通道
- `.enterCmux()` / `.exitCmux()` — CMUX 生命周期
- `.enterDataMode()` / `.exitDataMode()` — 数据模式

**Cellular 是编排层和事件源。** Cellular 在独立线程中：
1. 调用 Modem 的 AT 引擎查询硬件状态（SIM、信号、注册等）
2. 根据查询结果驱动内部状态机（Phase 转换）
3. 将状态变化映射为 `CellularPayload`，通过 `injector.invoke(payload)` 推入 Bus（应用在创建 Cellular 时传入 `bus.Injector(.cellular)`）

### 3.4 Layer diagram

```
+-----------------------------------------------------------+
|  Application (AppRuntime)                                  |
|    loop: r = rt.recv(); rt.dispatch(r.value); if dirty → render |
+-----------------------------------------------------------+
|                    Injector boundary                        |
|  Cellular 通过 bus.Injector(.cellular) 拿到 EventInjector，  |
|  在 tick 内 injector.invoke(CellularPayload) 推事件入 Bus。  |
|  Bus 内部 in_ch → middlewares → out_ch；主循环 rt.recv() 取事件。 |
+-----------------------------------------------------------+
|  pkg/cellular/                                             |
|                                                            |
|  cellular.zig -- event source + state machine              |
|    owns: Modem, injector (EventInjector(CellularPayload)), worker, state |
|    run(): poll modem → drive state → injector.invoke(payload) |
|  types.zig -- shared types (incl. CellularPayload)        |
|                                                            |
|  modem/                                                    |
|    modem.zig -- hardware driver (comptime Module param)    |
|      owns: Io(s), CMUX (optional), AtEngine                |
|      exposes: .at(), .pppIo(), .enterCmux(), .exitCmux()   |
|    sim.zig / signal.zig -- use modem.at() for AT commands  |
|    profiles/quectel.zig, profiles/simcom.zig -- module profiles
|      (commands, URCs, init sequence). Selected via comptime Module |
|                                                            |
|  at/                                                       |
|    engine.zig -- AT command engine (sendRaw/send/pumpUrcs) |
|    commands.zig -- typed AT command structs (comptime)     |
|    parse.zig -- AT response pure parsing functions         |
|    cmux.zig -- GSM 07.10 CMUX framing                     |
|    urcs.zig -- typed URC definitions (comptime structs)    |
|                                                            |
|  io/                                                       |
|    io.zig -- generic Io interface + fromUart/fromSpi       |
|    trace.zig -- TraceIo decorator (logs read/write bytes)  |
|    mock.zig -- MockIo (linear buffers, test only)           |
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
|  Test:    MockIo (linear buffers)                          |
+-----------------------------------------------------------+
|  lwIP PPP (external — 待 main 重构后由 pkg/lwip 提供)        |
|  Consumes modem.pppIo() via netlink abstraction            |
+-----------------------------------------------------------+
```

### 3.5 Event flow

```
Worker thread (Cellular.run)                    Main thread (AppRuntime)
┌──────────────────────────┐                   ┌──────────────────────────┐
│ loop:                    │                   │ loop:                    │
│   modem.at().pumpUrcs()  │                   │   r = rt.recv()          │
│   sim.getStatus()        │                   │   if (!r.ok) break       │
│   signal.getStrength()   │  CellularPayload   │   rt.dispatch(r.value)   │
│   update internal phase  │  injector.invoke() │     → Bus 中间件链        │
│   if phase changed:      │ ───────────────>  │     → store.dispatch()   │
│     injector.invoke(     │  推入 Bus in_ch   │   if rt.isDirty():       │
│       payload)           │                   │     drive outputs        │
│   sleep(poll_interval)   │                   │   (无 selector.poll)     │
└──────────────────────────┘                   └──────────────────────────┘
```

### 3.6 Runtime 与依赖（R36 对齐 main）

Cellular/Modem 实现与 plan 中涉及的 runtime 引用如下，与 main 分支一致：

| 用途 | 正确引用 | 说明 |
|------|----------|------|
| 事件通道（Bus 内部） | `runtime/channel_factory.zig` | Bus 使用 `ChannelFactory(backend).Channel(EventType)` 生成内部 in_ch/out_ch。Cellular **不直接使用** Channel，仅通过 Injector 推事件。 |
| 同步原语（Modem/CMUX/线程） | `runtime/sync/notify.zig`、`runtime/sync/mutex.zig`、`runtime/sync/condition.zig` | 原 `runtime/sync.zig` 已拆分为子模块。Modem、Cmux、Cellular 的 Thread/Notify 等使用 `sync.notify`（及按需 mutex/condition）。 |
| 线程、时间 | `runtime/thread.zig`、`runtime/time.zig` | 不变。 |

**不再使用：** `runtime/channel.zig`（已移除，由 `runtime/channel_factory.zig` 取代）、`runtime/select.zig`（已移除）、单文件 `runtime/sync.zig`（已拆分为 sync/*.zig）。

### 3.7 Runtime 合约：Thread / Notify / Time（Cellular/Modem/CMUX 注入）

Cellular、Modem、Cmux 通过 comptime 注入 `Thread`、`Notify`、`Time`。以下为各类型必选 API，来自 `runtime/thread.zig`、`runtime/sync/notify.zig`、`runtime/time.zig`；实现时按此合约注入平台实现（如 ESP32 的 RTOS 封装、主机端的 std.Thread）。

**Thread（runtime/thread.zig）**

- 通过 `thread.Thread(Backend)` 构造；Backend 须实现：
  - `spawn(config: SpawnConfig, task: TaskFn, ctx: ?*anyopaque) anyerror!Backend` — 启动新线程，执行 `task(ctx)`。
  - `join(self: *Backend) void` — 等待线程结束。
  - `detach(self: *Backend) void` — 分离线程（不再 join）。
- `TaskFn = *const fn (?*anyopaque) void`；`SpawnConfig` 含 `stack_size`、`priority`、`name`、`core_id`、`allocator` 等（见 runtime 定义）。
- 用途：Cellular worker 线程、CMUX pump 线程。

**Notify（runtime/sync/notify.zig）**

- 通过 `sync.Notify(Backend)` 构造；Backend 须实现：
  - `init() Backend` — 初始化。
  - `deinit(self: *Backend) void` — 释放。
  - `signal(self: *Backend) void` — 唤醒一个等待者。
  - `wait(self: *Backend) void` — 阻塞直到被 signal。
  - `timedWait(self: *Backend, timeout_ns: u64) bool` — 阻塞最多 timeout_ns 纳秒；若被 signal 返回 true，超时返回 false。
- 用途：CMUX 各虚拟通道的「有数据到达」通知（channelIo 的 pollFn 内用 timedWait）；可选用于 Cellular worker 与主线程同步。

**Time（runtime/time.zig，Q6 已用）**

- `nowMs() u64` — 当前毫秒时间戳。
- `sleepMs(ms: u32) void` — 休眠指定毫秒。
- 用途：AtEngine 超时循环、tick 间隔；测试用 FakeTime。

---

## 4. Directory Tree

```
src/pkg/cellular/
├── types.zig              shared types + CellularEvent (no logic, no deps)
├── cellular.zig           event source + Control (Cellular) — owns Modem, Injector, request_queue, response_channel; .control() → CellularControl (R37)
├── io/
│   ├── io.zig             generic Io interface + fromUart/fromSpi
│   ├── trace.zig          TraceIo decorator (logs read/write bytes)
│   └── mock.zig           MockIo (linear buffers, test only)
├── at/
│   ├── engine.zig         AT command engine (sendRaw/send/pumpUrcs)
│   ├── commands.zig       typed AT command definitions (comptime structs)
│   ├── parse.zig          AT response parsing (pure functions)
│   ├── cmux.zig           GSM 07.10 CMUX framing
│   └── urcs.zig           typed URC definitions (comptime structs)
├── modem/
│   ├── modem.zig          hardware driver (Modem) — owns Io/CMUX/AtEngine, NO state machine
│   ├── sim.zig            SIM card management (uses AtEngine)
│   ├── signal.zig         signal quality monitoring (uses AtEngine)
│   └── profiles/
│       ├── quectel.zig    Quectel module profile: commands, URCs, init sequence
│       ├── simcom.zig     SIMCom module profile: commands, URCs, init sequence
│       └── quectel_stub.zig  Step 8 placeholder Module
├── voice.zig              voice call management (phase 2)
└── apn.zig                APN auto-resolve (phase 2)

test/unit/pkg/cellular/
├── types_test.zig         types unit tests
├── cellular_test.zig      Cellular state machine + event emission tests
├── io/
│   ├── io_test.zig        Io interface + MockIo tests
│   └── trace_test.zig    TraceIo decorator tests
├── at/
│   ├── commands_test.zig  AT command type tests (write/parse, comptime checks)
│   ├── parse_test.zig     AT parsing pure function tests
│   ├── engine_test.zig    AT engine tests (uses MockIo)
│   ├── cmux_test.zig      CMUX framing tests (uses MockIo)
│   └── urcs_test.zig     URC type tests (parse, dispatch)
└── modem/
    ├── modem_test.zig     Modem routing tests (no reducer)
    ├── sim_test.zig       SIM management tests (uses MockIo)
    ├── signal_test.zig    signal quality tests (uses MockIo)
    └── profiles/
        ├── quectel_test.zig   Quectel-specific command/URC tests
        └── simcom_test.zig    SIMCom-specific command/URC tests
```

Changes to existing files:
```
src/mod.zig            add pkg.cellular exports
test/unit/mod.zig      add cellular test imports
```

No HAL changes. No runtime changes.

---

## 5. File-by-File Specification

### 5.1 types.zig

All shared types. No logic, no dependencies.

```zig
CellularPhase = enum { off, probing, at_configuring, checking_sim, registering, registered, dialing, connected, disconnecting, error };
SimStatus = enum { not_inserted, pin_required, puk_required, ready, error };
RAT = enum { none, gsm, gprs, edge, umts, hsdpa, lte };  // Radio Access Technology
CellularRegStatus = enum { not_registered, registered_home, searching, denied, registered_roaming, unknown };
VoiceCallState = enum { idle, incoming, dialing, alerting, active };

CellularSignalInfo = struct {
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

ModemError = enum {
    at_timeout, at_fatal, sim_not_inserted, sim_pin_required, sim_error,
    cmux_failed, registration_denied, registration_failed, ppp_failed, config_failed,
};

ModemState = struct {
    phase: CellularPhase = .off,
    sim: SimStatus = .not_inserted,
    registration: CellularRegStatus = .not_registered,
    network_type: RAT = .none,
    signal: ?CellularSignalInfo = null,
    modem_info: ?ModemInfo = null,
    sim_info: ?SimInfo = null,
    error_reason: ?ModemError = null,   // 仅 phase==error 时有意义；retry 时清空（见 6.1）
    at_timeout_count: u8 = 0,           // 连续 at_timeout；见 6.1
};

ModemEvent = union(enum) {
    power_on, power_off, retry, stop: void,
    dial_requested: void,
    bootstrap_probe_ok, bootstrap_echo_ok, bootstrap_cmee_ok: void,
    sim_status_reported: SimStatus,
    network_registration: CellularRegStatus,
    bootstrap_at_error: ModemError,
    at_timeout: void,
    dial_succeeded, dial_failed, ip_obtained, ip_lost: void,
    signal_updated: CellularSignalInfo,
};

APNConfig = struct {
    apn: []const u8,
    username: []const u8 = "",
    password: []const u8 = "",
};

CmuxChannelRole = enum { at, ppp };

CmuxChannelConfig = struct {
    dlci: u8,
    role: CmuxChannelRole,
};

ModemConfig = struct {
    -- CMUX settings (only used in single-channel mode). User-configurable: DLCI and role (at/ppp) per channel; init validates, enterCmux uses this (see 5.6.1).
    cmux_channels: []const CmuxChannelConfig = &.{
        .{ .dlci = 1, .role = .ppp },
        .{ .dlci = 2, .role = .at },
    },
    cmux_baud_rate: u32 = 921600,

    -- AT engine settings
    at_timeout_ms: u32 = 5000,
    max_urc_handlers: u8 = 16,

    -- PDP context ID (used in AT+CGDCONT=<cid>,... and AT+CGACT=1,<cid>)
    context_id: u8 = 1,
};
```

**Control 类型：** ControlRequestTag、ControlRequest、ControlResponse（及 SendAtPayload 等）在 5.8.1 中定义；实现时放在 types.zig 或 cellular.zig 内并导出，供 Cellular/worker 与 CellularControl 共用。

### 5.2 io/io.zig

Type-erased read/write/poll interface. The universal transport abstraction.

`read()` is **non-blocking**: returns `WouldBlock` when no data is available.
Callers use `poll(timeout_ms)` to efficiently wait for data before reading.

`pollFn` is **required** for all Io implementations. Each implementation provides
its most efficient wait mechanism behind the same interface:

| Io type | pollFn implementation |
|---------|----------------------|
| UART (ESP32/Beken) | Hardware interrupt + RTOS semaphore |
| USB serial (Linux/Mac) | POSIX `poll()` syscall |
| CMUX virtual channel | `Notify.timedWait()` (signaled by pump thread) |
| MockIo (test) | Check rx 有未读数据 (rx_pos < rx_len)，忽略 timeout |

```zig
pub const IoError = error{ WouldBlock, Timeout, Closed, IoError };

pub const PollFlags = packed struct {
    readable: bool = false,
    writable: bool = false,
    _padding: u6 = 0,
};

pub const Io = struct {
    ctx: *anyopaque,
    readFn: *const fn (*anyopaque, []u8) IoError!usize,
    writeFn: *const fn (*anyopaque, []const u8) IoError!usize,
    pollFn: *const fn (*anyopaque, i32) PollFlags,

    pub fn read(self: Io, buf: []u8) IoError!usize;
    pub fn write(self: Io, buf: []const u8) IoError!usize;
    pub fn poll(self: Io, timeout_ms: i32) PollFlags;
};

-- Helpers to wrap HAL types into Io
pub fn fromUart(comptime UartType: type, ptr: *UartType) Io;
pub fn fromSpi(comptime SpiType: type, ptr: *SpiType) Io;

-- 测试用传输由 MockIo 提供（见 8.1），无需单独的 fromBufferPair。
```

### 5.2.1 io/trace.zig (R29)

TraceIo Decorator. Wraps any `Io`, logs all read/write bytes through a user-provided
log function. Zero-intrusion: insert between any Io and its consumer without code changes.
Inspired by warthog618/modem `trace` package.

```zig
pub const TraceDirection = enum { tx, rx };

pub const TraceFn = *const fn (TraceDirection, []const u8) void;

pub fn wrap(inner: Io, log_fn: TraceFn) Io;
```

**Usage:**
```zig
const raw_io = io.fromUart(uart_hal, &uart);
const traced = trace.wrap(raw_io, myLogFn);
var modem = Modem.init(.{ .io = traced, ... });
-- All AT traffic now logged via myLogFn, modem is unaware
```

**Implementation:** `wrap()` returns a new `Io` whose:
- `readFn`: calls `inner.read()`, then `log_fn(.rx, data[0..n])`
- `writeFn`: calls `log_fn(.tx, buf)`, then `inner.write(buf)`
- `pollFn`: delegates to `inner.poll()` (no logging needed)

**Design notes:**
- log_fn is a bare function pointer (not comptime generic) — TraceIo is a runtime Decorator, same as Io's type-erased design
- Can be stacked: `trace.wrap(trace.wrap(io, hexLog), asciiLog)`
- Production builds simply skip the wrap call — zero overhead

### 5.3 at/parse.zig

Pure parsing functions. No state, no IO, no dependencies except types.zig.
Extracted for independent testability.

```zig
pub fn isOk(line: []const u8) bool;
pub fn isError(line: []const u8) bool;
pub fn parseCmeError(line: []const u8) ?u16;
pub fn parseCmsError(line: []const u8) ?u16;
pub fn parsePrefix(line: []const u8, prefix: []const u8) ?[]const u8;
pub fn parseCsq(value: []const u8) ?CellularSignalInfo;
pub fn parseCpin(value: []const u8) ?SimStatus;
pub fn parseCreg(value: []const u8) ?CellularRegStatus;
pub fn rssiToDbm(csq: u8) i8;
pub fn rssiToPercent(dbm: i8) u8;
```

### 5.4 at/commands.zig

Typed AT command definitions. Each command is a struct with comptime metadata
and write/parse methods. Inspired by Rust's `atat` crate pattern.

**Command contract:** every command struct must provide:

| Field/Method | Type | Description |
|---|---|---|
| `Response` | `type` (comptime) | The parsed response type (e.g. `CellularSignalInfo`, `SimStatus`, `void`) |
| `prefix` | `[]const u8` (comptime) | Response line prefix for matching (e.g. `"+CSQ"`) |
| `timeout_ms` | `u32` (comptime) | Command-specific timeout |
| `write(buf)` or `write(self, buf)` | `fn -> usize` | Serialize command bytes into buffer |
| `parseResponse(line)` | `fn -> ?Response` | Parse a response line into the Response type |
| `match(line)` | `fn -> enum{complete,need_more,unknown}` | *(optional)* Custom response completeness matcher. If absent, engine uses default OK/ERROR matching |

**No-param commands** use `write(buf: []u8) usize` (type-level function).
**Parameterized commands** use `write(self: Self, buf: []u8) usize` (instance method).
**Custom response matching:** some commands (e.g. `CONNECT`, multi-line responses) need non-standard end-of-response detection. These commands provide an optional `match` method. The engine checks `@hasDecl(Cmd, "match")` at comptime and uses it when present, otherwise falls back to standard OK/ERROR/timeout matching.

```zig
const std = @import("std");
const parse = @import("parse.zig");
const types = @import("../types.zig");

// ============================================================================
// 1. General (V.25ter / 3GPP 27.007 Ch4)
//    Basic module identification. Standard across all vendors.
//    AT, ATI, +CGMI, +CGMM, +CGMR, +CGSN
// ============================================================================

pub const Probe = struct {
    pub const Response = void;
    pub const prefix = "";
    pub const timeout_ms: u32 = 2000;
    pub fn write(buf: []u8) usize {
        const cmd = "AT\r";
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }
    pub fn parseResponse(_: []const u8) ?Response { return {}; }
};

pub const GetManufacturer = struct {
    pub const Response = types.ModemInfo;
    pub const prefix = "";
    pub const timeout_ms: u32 = 3000;
    pub fn write(buf: []u8) usize {
        const cmd = "AT+CGMI\r";
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }
    pub fn parseResponse(line: []const u8) ?Response { ... }
};

pub const GetModel = struct {
    pub const Response = types.ModemInfo;
    pub const prefix = "";
    pub const timeout_ms: u32 = 3000;
    pub fn write(buf: []u8) usize {
        const cmd = "AT+CGMM\r";
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }
    pub fn parseResponse(line: []const u8) ?Response { ... }
};

pub const GetFirmwareVersion = struct {
    pub const Response = types.ModemInfo;
    pub const prefix = "+CGMR";
    pub const timeout_ms: u32 = 3000;
    pub fn write(buf: []u8) usize {
        const cmd = "AT+CGMR\r";
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }
    pub fn parseResponse(line: []const u8) ?Response { ... }
};

pub const GetImei = struct {
    pub const Response = types.ModemInfo;
    pub const prefix = "";
    pub const timeout_ms: u32 = 3000;
    pub fn write(buf: []u8) usize {
        const cmd = "AT+CGSN\r";
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }
    pub fn parseResponse(line: []const u8) ?Response { ... }
};

// ============================================================================
// 2. Control (V.25ter / 3GPP 27.007 Ch5)
//    Module behavior: echo, result code format, error reporting, baud rate.
//    ATE, ATQ, ATV, +CMEE, +IPR, ATZ, AT&F, AT&W
// ============================================================================

pub const SetEcho = struct {
    pub const Response = void;
    pub const prefix = "";
    pub const timeout_ms: u32 = 2000;
    enable: bool,
    pub fn write(self: SetEcho, buf: []u8) usize {
        const cmd = if (self.enable) "ATE1\r" else "ATE0\r";
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }
    pub fn parseResponse(_: []const u8) ?Response { return {}; }
};

pub const SetErrorFormat = struct {
    pub const Response = void;
    pub const prefix = "";
    pub const timeout_ms: u32 = 2000;
    level: u8, // 0=disabled, 1=numeric, 2=verbose
    pub fn write(self: SetErrorFormat, buf: []u8) usize { ... }
    pub fn parseResponse(_: []const u8) ?Response { return {}; }
};

// -- Additional control: ATZ (reset), AT&F (factory defaults), AT&W (save profile)
// -- +IPR (baud rate), ATQ (quiet mode), ATV (verbose mode)
// -- Implement as needed per module profile.

// ============================================================================
// 3. SIM / Device Lock (3GPP 27.007 Ch8-9)
//    SIM card status, PIN management, IMSI/ICCID retrieval.
//    +CPIN, +CIMI, +CCID, +CLCK, +CPWD
// ============================================================================

pub const GetSimStatus = struct {
    pub const Response = types.SimStatus;
    pub const prefix = "+CPIN";
    pub const timeout_ms: u32 = 5000;
    pub fn write(buf: []u8) usize {
        const cmd = "AT+CPIN?\r";
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }
    pub fn parseResponse(line: []const u8) ?Response {
        const value = parse.parsePrefix(line, "+CPIN: ") orelse return null;
        return parse.parseCpin(value);
    }
};

pub const EnterPin = struct {
    pub const Response = void;
    pub const prefix = "";
    pub const timeout_ms: u32 = 10000;
    pin: []const u8,
    pub fn write(self: EnterPin, buf: []u8) usize {
        var pos: usize = 0;
        const head = "AT+CPIN=";
        @memcpy(buf[pos..][0..head.len], head);
        pos += head.len;
        @memcpy(buf[pos..][0..self.pin.len], self.pin);
        pos += self.pin.len;
        buf[pos] = '\r';
        return pos + 1;
    }
    pub fn parseResponse(_: []const u8) ?Response { return {}; }
};

pub const GetImsi = struct {
    pub const Response = types.SimInfo;
    pub const prefix = "";
    pub const timeout_ms: u32 = 5000;
    pub fn write(buf: []u8) usize {
        const cmd = "AT+CIMI\r";
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }
    pub fn parseResponse(line: []const u8) ?Response { ... }
};

pub const GetIccid = struct {
    pub const Response = types.SimInfo;
    pub const prefix = "+CCID";
    pub const timeout_ms: u32 = 5000;
    pub fn write(buf: []u8) usize {
        const cmd = "AT+CCID\r";
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }
    pub fn parseResponse(line: []const u8) ?Response { ... }
};

// -- Additional SIM: +CLCK (facility lock), +CPWD (change password)
// -- Implement as needed.

// ============================================================================
// 4. Mobile Control (3GPP 27.007 Ch6)
//    Radio functionality, operator selection, power modes.
//    +CFUN, +COPS, +CCLK
// ============================================================================

pub const SetFunctionality = struct {
    pub const Response = void;
    pub const prefix = "";
    pub const timeout_ms: u32 = 15000;
    level: u8, // 0=minimum, 1=full, 4=airplane
    pub fn write(self: SetFunctionality, buf: []u8) usize { ... }
    pub fn parseResponse(_: []const u8) ?Response { return {}; }
};

// -- Additional: +COPS (operator selection), +CCLK (clock)
// -- Implement as needed per module profile.

// ============================================================================
// 5. Network Service (3GPP 27.007 Ch7)
//    Registration status, signal quality, network selection.
//    +CREG, +CGREG, +CEREG, +CSQ, +COPS?
// ============================================================================

pub const GetSignalQuality = struct {
    pub const Response = types.CellularSignalInfo;
    pub const prefix = "+CSQ";
    pub const timeout_ms: u32 = 5000;
    pub fn write(buf: []u8) usize {
        const cmd = "AT+CSQ\r";
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }
    pub fn parseResponse(line: []const u8) ?Response {
        const value = parse.parsePrefix(line, "+CSQ: ") orelse return null;
        return parse.parseCsq(value);
    }
};

pub const GetRegistration = struct {
    pub const Response = types.CellularRegStatus;
    pub const prefix = "+CGREG";
    pub const timeout_ms: u32 = 5000;
    pub fn write(buf: []u8) usize {
        const cmd = "AT+CGREG?\r";
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }
    pub fn parseResponse(line: []const u8) ?Response {
        const value = parse.parsePrefix(line, "+CGREG: ") orelse return null;
        return parse.parseCreg(value);
    }
};

pub const SetRegistrationUrc = struct {
    pub const Response = void;
    pub const prefix = "";
    pub const timeout_ms: u32 = 2000;
    mode: u8, // 0=disable, 1=enable, 2=enable+location
    pub fn write(self: SetRegistrationUrc, buf: []u8) usize { ... }
    pub fn parseResponse(_: []const u8) ?Response { return {}; }
};

// -- Additional: +CEREG (EPS registration), +COPS? (current operator)
// -- Extended signal: vendor-specific (Quectel +QCSQ, SIMCom +CPSI)

// ============================================================================
// 6. PDP / Packet Domain (3GPP 27.007 Ch10)
//    Data connection setup: APN configuration, PDP context, attach.
//    +CGDCONT, +CGATT, +CGACT, +CGDATA
// ============================================================================

pub const SetApn = struct {
    pub const Response = void;
    pub const prefix = "";
    pub const timeout_ms: u32 = 5000;
    cid: u8,
    apn: []const u8,
    pub fn write(self: SetApn, buf: []u8) usize { ... }
    pub fn parseResponse(_: []const u8) ?Response { return {}; }
};

pub const GetAttachStatus = struct {
    pub const Response = types.AttachStatus;
    pub const prefix = "+CGATT";
    pub const timeout_ms: u32 = 5000;
    pub fn write(buf: []u8) usize {
        const cmd = "AT+CGATT?\r";
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }
    pub fn parseResponse(line: []const u8) ?Response { ... }
};

// -- Additional: +CGACT (activate PDP), +CGDATA (enter data mode)
// -- Vendor-specific PDP: Quectel +QIACT, SIMCom +CSTT/+CIICR/+CIFSR

// ============================================================================
// 7. Call Control (V.25ter / 3GPP 27.007 Ch6-7)
//    Voice and data call management.
//    ATD, ATH, ATA, +CLCC, +CHUP
// ============================================================================

pub const Dial = struct {
    pub const Response = void;
    pub const prefix = "";
    pub const timeout_ms: u32 = 30000;
    apn: []const u8,
    pub fn write(self: Dial, buf: []u8) usize {
        const head = "ATD*99***1#\r";
        @memcpy(buf[0..head.len], head);
        return head.len;
    }
    pub fn parseResponse(_: []const u8) ?Response { return {}; }

    pub const MatchResult = enum { complete, need_more, unknown };
    pub fn match(line: []const u8) MatchResult {
        if (std.mem.startsWith(u8, line, "CONNECT")) return .complete;
        if (std.mem.startsWith(u8, line, "NO CARRIER")) return .complete;
        if (std.mem.startsWith(u8, line, "BUSY")) return .complete;
        return .unknown;
    }
};

pub const Hangup = struct {
    pub const Response = void;
    pub const prefix = "";
    pub const timeout_ms: u32 = 5000;
    pub fn write(buf: []u8) usize {
        const cmd = "ATH\r";
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }
    pub fn parseResponse(_: []const u8) ?Response { return {}; }
};

// -- Additional: ATA (answer), +CLCC (list current calls), +CHUP (hangup)
// -- Voice dial: ATD<number>; (semicolon for voice)

// ============================================================================
// 8. SMS (3GPP 27.005)
//    Short message service. Text and PDU mode.
//    +CMGF, +CMGS, +CMGR, +CMGL, +CMGD, +CNMI, +CSCA
// ============================================================================

// -- SMS commands are not needed for the core cellular state machine.
// -- Implement in module profiles or a dedicated sms.zig when SMS is required.
// -- Key commands:
// --   +CMGF (message format: 0=PDU, 1=text)
// --   +CMGS (send message) — needs custom match for '>' prompt
// --   +CMGR (read message)
// --   +CMGL (list messages)
// --   +CMGD (delete message)
// --   +CNMI (new message indication URC config)
// --   +CSCA (service center address)

// ============================================================================
// 9. CMUX / Multiplexer (3GPP 27.010)
//    Channel multiplexing over a single UART.
//    +CMUX
// ============================================================================

pub const SetCmux = struct {
    pub const Response = void;
    pub const prefix = "";
    pub const timeout_ms: u32 = 5000;
    pub fn write(buf: []u8) usize {
        const cmd = "AT+CMUX=0\r";
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }
    pub fn parseResponse(_: []const u8) ?Response { return {}; }
};

// ============================================================================
// 10. TCP/IP (vendor-specific)
//     Internal TCP/IP stack commands. Highly vendor-dependent.
//     u-blox: +USOCR/+USOWR/+USORD/+USOCL
//     Quectel: +QIOPEN/+QISEND/+QIRD/+QICLOSE
//     SIMCom: +CIPSTART/+CIPSEND/+CIPCLOSE
// ============================================================================

// -- Not defined here. These belong in module profiles (profiles/quectel.zig, profiles/simcom.zig)
// -- or a dedicated tcp.zig if using the modem's internal stack.
// -- Our architecture prefers PPP + external lwIP, so these are rarely needed.

// ============================================================================
// 11. HTTP / MQTT / FTP (vendor-specific)
//     Application-layer protocols built into some modules.
//     Quectel: +QHTTPURL/+QHTTPGET/+QMTOPEN/+QMTCONN
//     SIMCom: +HTTPINIT/+HTTPPARA/+HTTPACTION
// ============================================================================

// -- Not defined here. Vendor-specific, implement in module profiles when needed.

// ============================================================================
// 12. GNSS / GPS (vendor-specific)
//     Positioning commands for modules with integrated GNSS.
//     Quectel: +QGPS/+QGPSLOC
//     SIMCom: +CGNSINF/+CGNSPWR
// ============================================================================

// -- Not defined here. Implement in module profiles when needed.

// ============================================================================
// 13. Power / Sleep (vendor-specific)
//     Low-power modes, PSM, eDRX.
//     +CPSMS, +CEDRXS
//     Quectel: +QSCLK
//     SIMCom: +CSCLK
// ============================================================================

// -- Not defined here. Implement in module profiles when needed.
// -- Standard +CPSMS and +CEDRXS may be promoted here if commonly used.
```

**Benefits:**
- Compile-time type safety: `engine.send(commands.GetSignalQuality, .{})` returns `?CellularSignalInfo`
- Typo-proof: misspelled command struct name → compile error
- Self-documenting: each command struct is its own specification
- Testable: write/parse methods are pure functions, independently testable

### 5.5 at/engine.zig

AT command engine. Reads/writes through Io. Transport-agnostic.

Time is injected via comptime generic (aligned with existing pkg style: button, timer, audio, etc.).
Test code passes `FakeTime`, ESP32 passes real `Time`.

```zig
pub const AtStatus = enum { ok, error, cme_error, cms_error, timeout, overflow };

pub const UrcHandler = struct {
    prefix: []const u8,
    ctx: ?*anyopaque,
    callback: *const fn (?*anyopaque, []const u8) void,
};

-- R39: 单一平坦缓冲区，大小由 comptime 参数控制（参考 atat 的 const generic 模式）。
-- 不再按行分割存储。响应数据保留在 rx_buf 中，由 Digester 流式处理。
-- 默认 1024 字节足够常规 AT 命令；AT+COPS=? / AT+CMGL 等长响应需要 2048+。
pub fn AtEngine(comptime Time: type, comptime buf_size: usize) type {
    return struct {
        const Self = @This();

        pub const AtResponse = struct {
            status: AtStatus,
            body: []const u8,     -- 响应正文（指向 rx_buf 内的切片，不含最终 OK/ERROR）
            error_code: ?u16,

            pub fn lineIterator(self: *const @This()) LineIterator;
        };

        pub const LineIterator = struct {
            data: []const u8,
            pos: usize = 0,
            pub fn next(self: *LineIterator) ?[]const u8;
        };

        io: Io,
        time: Time,
        rx_buf: [buf_size]u8,
        rx_pos: usize,
        urc_handlers: [16]?UrcHandler,

        pub fn init(io: Io, time: Time) Self;
        pub fn setIo(self: *Self, io: Io) void;

        -- Raw send: untyped, for low-level / custom commands
        pub fn sendRaw(self: *Self, cmd: []const u8, timeout_ms: u32) AtResponse;

        -- Raw send with custom matcher: used when Cmd provides a match method
        const MatchFn = *const fn ([]const u8) enum { complete, need_more, unknown };
        pub fn sendRawWithMatcher(self: *Self, cmd: []const u8, timeout_ms: u32, matcher: MatchFn) AtResponse;

        -- Typed send: comptime command type, returns typed result
        -- Cmd must satisfy the command contract (see 5.4 at/commands.zig).
        -- If Cmd has a `match` method, uses it for response completeness detection
        -- instead of the default OK/ERROR matcher.
        pub fn send(self: *Self, comptime Cmd: type, cmd: anytype) SendResult(Cmd) {
            comptime {
                _ = Cmd.Response;
                _ = Cmd.prefix;
                _ = @as(u32, Cmd.timeout_ms);
            }
            var cmd_buf: [256]u8 = undefined;
            const cmd_len = if (@sizeOf(Cmd) > 0)
                cmd.write(&cmd_buf)
            else
                Cmd.write(&cmd_buf);

            const raw = if (@hasDecl(Cmd, "match"))
                self.sendRawWithMatcher(cmd_buf[0..cmd_len], Cmd.timeout_ms, Cmd.match)
            else
                self.sendRaw(cmd_buf[0..cmd_len], Cmd.timeout_ms);

            return .{
                .status = raw.status,
                .raw = raw,
                .value = if (raw.status == .ok) parseTyped(Cmd, &raw) else null,
            };
        }

        pub fn SendResult(comptime Cmd: type) type {
            return struct {
                status: AtStatus,
                raw: AtResponse,
                value: ?Cmd.Response,
            };
        }

        fn parseTyped(comptime Cmd: type, raw: *const AtResponse) ?Cmd.Response {
            if (Cmd.Response == void) return {};
            var iter = raw.body.lineIterator();
            while (iter.next()) |line| {
                if (Cmd.parseResponse(line)) |result| return result;
            }
            return null;
        }

        pub fn registerUrc(self: *Self, prefix: []const u8, handler: UrcHandler) bool;
        pub fn unregisterUrc(self: *Self, prefix: []const u8) void;
        pub fn pumpUrcs(self: *Self) void;
    };
}
```

**Usage comparison:**

Before (untyped):
```zig
const resp = at.sendRaw("AT+CSQ\r", 5000);
const line = resp.firstLine() orelse return error.NoResponse;
const value = parse.parsePrefix(line, "+CSQ: ") orelse return error.ParseError;
const signal = parse.parseCsq(value) orelse return error.ParseError;
```

After (typed):
```zig
const result = at.send(commands.GetSignalQuality, .{});
if (result.value) |signal| { ... }  -- signal is CellularSignalInfo, compile-time guaranteed
```

### 5.6 at/cmux.zig

GSM 07.10 CMUX framing. Only used internally by Modem in single-channel mode.

Pump runs in an independent thread (Thread comptime param).
Each virtual channel has a Notify for signaling data arrival to waiters.
The channelIo() returns Io whose pollFn wraps Notify.timedWait().

```zig
pub const Frame = struct {
    dlci: u8,
    control: u8,
    data: []const u8,
};

pub fn Cmux(comptime Thread: type, comptime Notify: type, comptime max_channels: u8) type {
    return struct {
        const Self = @This();
        io: Io,                                -- underlying single-channel transport
        channels: [max_channels]ChannelBuf,
        notifiers: [max_channels]Notify,       -- per-channel data arrival notification
        active: bool,
        pump_thread: ?Thread,

        pub fn init(io: Io) Self;
        pub fn open(self: *Self, dlcis: []const u8) !void;  -- SABM/UA only, caller sends AT+CMUX=0 before calling
        pub fn close(self: *Self) void;
        pub fn channelIo(self: *Self, dlci: u8) ?Io;  -- pollFn wraps Notify.timedWait
        pub fn startPump(self: *Self) !void;            -- spawn pump thread
        pub fn stopPump(self: *Self) void;
        pub fn pump(self: *Self) void;                  -- single pump iteration (called by thread)

        pub fn encodeFrame(frame: Frame, out: []u8) usize;
        pub fn decodeFrame(data: []const u8) ?Frame;
        pub fn calcFcs(data: []const u8) u8;
    };
}
```

### 5.6.1 可配置通道实施规格（R41）

**目的：** 用户通过 `ModemConfig.cmux_channels` 指定各 DLCI 与角色（.at / .ppp）的对应关系，Modem 在 single-channel 模式下据此执行 enterCmux，不做硬编码 DLCI。

**校验（Modem.init 单通道模式）：**

- 在 `init` 时若 `data_io == null`（即将使用 CMUX），必须校验 `config.cmux_channels`：
  - 恰好存在一个 `role == .at`、一个 `role == .ppp`（当前设计仅使用 AT + PPP 两通道）。
  - 所有条目的 `dlci` 互不重复，且落在 Cmux 支持范围内（例如 1..63，DLCI 0 为信令通道由实现内部使用则可不暴露）。
  - `config.cmux_channels.len <= Cmux 的 max_channels`（Modem 选用的 Cmux 泛型参数需 >= 通道数）。
- 校验失败：`init` 返回错误（如 `error.InvalidCmuxConfig`），在文档中说明合法配置示例与各模组常见 DLCI 分配。

**enterCmux 使用 config：**

- 从 `config.cmux_channels` 得到 DLCI 列表：按顺序收集所有 `dlci`，传入 `cmux.open(dlcis)`（顺序可与 SABM/UA 握手顺序一致，无强制要求）。
- 绑定 AT 通道：在 `config.cmux_channels` 中取 `role == .at` 的那条的 `dlci`，令 `at_engine.setIo(cmux.channelIo(dlci))`。
- 绑定 PPP 通道：取 `role == .ppp` 的那条的 `dlci`，令 `self.data_io = cmux.channelIo(dlci)`，使 `pppIo()` 返回该 Io。

**max_channels 与 config 的关系：**

- Cmux 类型为 `Cmux(Thread, Notify, max_channels)`。可选方案：（A）Modem 使用固定 `max_channels`（如 8），要求 `config.cmux_channels.len <= 8`；（B）由构建 Modem 的调用方根据配置传入满足 `>= cmux_channels.len` 的 comptime 常量。推荐（A）以简化泛型实例化，在文档中约定「用户配置的通道数不超过 8」。
- 若采用（A），在 init 校验中增加：`config.cmux_channels.len <= MODEM_CMUX_MAX_CHANNELS`（常量与 Cmux 泛型一致）。

**默认值语义：**

- `ModemConfig.cmux_channels` 默认 `&.{ .{ .dlci = 1, .role = .ppp }, .{ .dlci = 2, .role = .at } }` 对应常见 Quectel 等模组（DLCI 1 为数据、2 为 AT）。用户若模组不同，覆盖该字段即可。

**测试：**

- 单测：传入自定义 `cmux_channels`（如交换 at/ppp 的 dlci 或使用 3 通道中 2 个），MockIo 模拟 CMUX 帧，验证 enterCmux 后 at() 与 pppIo() 使用正确的 DLCI。
- 文档：在 types.zig 或 modem.zig 的 ModemConfig 注释中给出 Quectel/Simcom 等常见 DLCI 表链接或说明。

### 5.6.2 at/urcs.zig (R29)

Typed URC (Unsolicited Result Code) definitions. Each URC is a struct with
comptime prefix and parse method, unified with R28 command type pattern.
Inspired by ublox-cellular-rs typed `Urc` enum.

**URC contract:** every URC struct must provide:

| Field/Method | Type | Description |
|---|---|---|
| `prefix` | `[]const u8` (comptime) | URC line prefix for matching (e.g. `"+CRING"`) |
| `parse(line)` | `fn -> ?Payload` | Parse the URC line into a typed payload |

```zig
const types = @import("../types.zig");
const parse = @import("parse.zig");

pub const NetworkRegistrationUrc = struct {
    pub const Payload = types.CellularRegStatus;
    pub const prefix = "+CREG";

    pub fn parseUrc(line: []const u8) ?Payload {
        const value = parse.parsePrefix(line, "+CREG: ") orelse return null;
        return parse.parseCreg(value);
    }
};

pub const SimStatusUrc = struct {
    pub const Payload = types.SimStatus;
    pub const prefix = "+CPIN";

    pub fn parseUrc(line: []const u8) ?Payload {
        const value = parse.parsePrefix(line, "+CPIN: ") orelse return null;
        return parse.parseCpin(value);
    }
};

pub const SimHotplugUrc = struct {
    pub const Payload = struct { sim_inserted: bool };
    pub const prefix = "+QSIMSTAT";

    pub fn parseUrc(line: []const u8) ?Payload { ... }
};

pub const RingUrc = struct {
    pub const Payload = void;
    pub const prefix = "+CRING";

    pub fn parseUrc(_: []const u8) ?Payload { return {}; }
};

-- Aggregate: list of all known URCs for typed dispatch
pub const AllUrcs = .{
    NetworkRegistrationUrc,
    SimStatusUrc,
    SimHotplugUrc,
    RingUrc,
};
```

**Typed URC dispatch in AtEngine:**

AtEngine gains a comptime-parameterized URC pump that auto-matches and parses:

```zig
pub fn pumpUrcsTyped(self: *Self, comptime Urcs: anytype, ctx: anytype) void {
    while (self.readLine()) |line| {
        inline for (Urcs) |Urc| {
            if (parse.parsePrefix(line, Urc.prefix)) |_| {
                if (Urc.parseUrc(line)) |payload| {
                    ctx.onUrc(Urc, payload);
                    break;
                }
            }
        }
    }
}
```

**Benefits:**
- Type-safe: each URC's payload type is known at compile time
- Self-documenting: URC struct is its own specification
- Unified pattern: commands (R28) and URCs (R29) share the same struct-with-prefix-and-parse design
- Extensible: add a new URC = add a struct + append to AllUrcs tuple

### 5.7 modem/modem.zig

Hardware driver. Owns transport, CMUX, AT engine. **No flux Store, no state machine.**

Comptime generics for platform deps (aligned with existing pkg style).
Io remains type-erased (runtime CMUX swap requirement).

```zig
pub fn Modem(
    comptime Thread: type,
    comptime Notify: type,
    comptime Time: type,
    comptime Module: type,
    comptime Gpio: type,
    comptime at_buf_size: usize,
) type {
    comptime {
        if (!hal.gpio.is(Gpio)) @compileError("Gpio must be a hal.gpio type");
    }

    const At = AtEngine(Time, at_buf_size);
    const CmuxType = Cmux(Thread, Notify, 4);

    return struct {
        const Self = @This();

        pub const PowerPins = struct {
            power_pin: ?u8 = null,    -- enable/disable supply (OutputPin)
            reset_pin: ?u8 = null,    -- hardware reset pulse (OutputPin)
            vint_pin: ?u8 = null,     -- power status feedback (InputPin, read-only)
        };

        pub const InitConfig = struct {
            -- Single-channel mode: provide io only. CMUX used internally.
            io: ?Io = null,

            -- Multi-channel mode: provide both. CMUX skipped.
            at_io: ?Io = null,
            data_io: ?Io = null,

            -- Time source
            time: Time,

            -- GPIO for power control (optional, null = no hardware pin control)
            gpio: ?*Gpio = null,
            pins: PowerPins = .{},

            -- Baud rate switch (optional, single-channel CMUX only)
            -- Called during enterCmux() after AT+IPR to switch local UART rate.
            -- null = no baud rate change (stay at initial rate).
            set_rate: ?*const fn (u32) anyerror!void = null,

            -- Modem settings
            config: ModemConfig = .{},
        };

        gpio: ?*Gpio,
        pins: PowerPins,
        mode: enum { single_channel, multi_channel },
        raw_io: ?Io,                   -- original single-channel Io (for CMUX)
        cmux: ?CmuxType,               -- only in single-channel mode
        at_engine: At,
        data_io: ?Io,                  -- PPP data channel (CMUX ch or direct)
        config: ModemConfig,
        time: Time,

        pub fn init(cfg: InitConfig) Self;
        pub fn deinit(self: *Self) void;

        -- Power control (uses injected Gpio)
        pub fn powerUp(self: *Self) !void;
            -- gpio.setLevel(power_pin, .high); sleepMs; poll vint_pin if present
        pub fn powerDown(self: *Self) void;
            -- gpio.setLevel(power_pin, .low)
        pub fn hardReset(self: *Self) !void;
            -- gpio.setLevel(reset_pin, .low); sleepMs(300); setLevel(.high)
        pub fn isPowered(self: *Self) ?bool;
            -- if vint_pin: gpio.getLevel(vint_pin) == .high; else null

        -- AT channel
        pub fn at(self: *Self) *At;

        -- PPP data IO (for lwIP)
        pub fn pppIo(self: *Self) ?Io;
            Returns:
            - multi-channel: data_io (always available after init)
            - single-channel: CMUX data channel Io (available after enterCmux)
            - null if data channel not yet established

        -- CMUX lifecycle (single-channel mode only)
        pub fn enterCmux(self: *Self) !void;
            Single-channel: sends AT+CMUX=0, opens DLCIs, starts pump thread, swaps AT engine Io.
            Multi-channel: no-op (already separated).

        pub fn exitCmux(self: *Self) void;
            Single-channel: stops pump thread, sends DISC, restores AT engine Io to raw transport.
            Multi-channel: no-op.

        pub fn isCmuxActive(self: *const Self) bool;

        -- Data mode
        pub fn enterDataMode(self: *Self) !void;
            Sends ATD*99#, waits for CONNECT.
            After this, pppIo() returns the data stream.

        pub fn exitDataMode(self: *Self) void;
            Sends +++ or ATH to exit data mode.
    };
}
```

### 5.8 cellular.zig

Event source + state machine. Owns Modem, EventInjector(CellularPayload), worker thread.
与 main 分支 Bus 对齐：不持有 Channel，由应用在 init 时传入 injector（通常为 `rt.bus.Injector(.cellular)`）。
Aligned with MotionPeripheral / ButtonPeripheral pattern（二者亦使用 Injector 推事件）。

**泛型参数说明：** 不再需要 `ChannelType`、`EventType`、`tag`；Cellular 只依赖 `Thread`、`Notify`、`Time` 与 injector 的 payload 类型（即 `CellularPayload`）。应用侧通过 Bus 的 InputSpec 定义 `.cellular = CellularPayload`，创建 Cellular 时传入 `bus.Injector(.cellular)` 即可。

```zig
pub fn Cellular(
    comptime Thread: type,
    comptime Notify: type,
    comptime Time: type,
    comptime Module: type,
    comptime Gpio: type,
    comptime at_buf_size: usize,
) type {
    const ModemType = Modem(Thread, Notify, Time, Module, Gpio, at_buf_size);
    const SimType = Sim(Time);
    const SignalType = Signal(Time);
    const InjectorType = EventInjector(CellularPayload);  -- 类型来自 pkg/event/bus.zig，Cellular 需 import 该模块取得 EventInjector

    return struct {
        const Self = @This();

        pub const Config = struct {
            poll_interval_ms: u32 = 1000,    -- worker tick 间隔；Q14 建议 1000 以配合 pumpUrcs 消费频率，避免 AT 通道积压；可改为 5000 但需加大 AT 通道 buffer
            thread_stack_size: usize = 8192,
        };

        modem: ModemType,
        sim: SimType,
        signal: SignalType,
        injector: InjectorType,               -- 由应用传入 bus.Injector(.cellular)
        config: Config,
        state: ModemState,                     -- internal state machine
        worker: ?Thread = null,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn init(allocator: std.mem.Allocator, modem_cfg: ModemType.InitConfig, injector: InjectorType, config: Config) !Self;
        pub fn deinit(self: *Self) void;

        pub fn start(self: *Self) !void;       -- spawn worker thread
        pub fn stop(self: *Self) void;         -- signal stop + join worker
        pub fn isRunning(self: *const Self) bool;

        -- Worker thread entry point (internal)
        fn workerMain(ctx: ?*anyopaque) void;

        -- Single tick: pumpUrcs → per-phase single AT → reduce → emit (internal)
        fn tick(self: *Self) void;

        -- Pure state transition (internal)
        fn reduce(state: *ModemState, event: ModemEvent) void;

        -- Emit: 状态变化时通过 injector.invoke(payload) 推入 Bus（internal）
        fn emitIfChanged(self: *Self, old_phase: CellularPhase) void;
    };
}
```

**Worker thread loop:**
```
fn workerMain(ctx) {
    while (self.running) {
        self.tick();
        self.time.sleepMs(self.config.poll_interval_ms);
    }
}

fn tick(self) {
    -- 1. Pump URCs from modem (every tick, regardless of phase)
    self.modem.at().pumpUrcs();

    -- 2. Per-phase action: each phase sends at most ONE AT command
    --    State transitions driven by single AT result + URC events.
    --    Aligned with quectel C / ublox-rs / Zephyr pattern.
    const old_phase = self.state.phase;
    const event: ?ModemEvent = switch (self.state.phase) {
        .off => null,
        .probing => self.probeAt(),             -- AT → bootstrap_probe_ok / bootstrap_at_error
        .at_configuring => self.nextInitAt(),  -- ATE0 → bootstrap_echo_ok; CMEE → bootstrap_cmee_ok
        .checking_sim => self.queryCpin(),     -- → sim_status_reported / bootstrap_at_error
        .registering => self.queryCereg(),     -- → network_registration / bootstrap_at_error（searching 等仍 phase=registering，继续 tick）
        .registered, .dialing, .connected, .disconnecting, .@"error" => null,
    };

    -- 3. Drive state machine if we got an event
    if (event) |ev| self.reduce(&self.state, ev);

    -- 4. Emit to Bus if phase or state changed
    self.emitIfChanged(old_phase);
}
```

**emitIfChanged 实现要点：** 根据 `old_phase` 与当前 `state` 的差异，构造对应的 `CellularPayload`（如 `phase_changed`、`signal_updated`、`sim_status_changed`、`registration_changed`、`error`），然后调用 `self.injector.invoke(payload)`。不调用任何 channel.send()。

**CellularPayload（与 Bus InputSpec 的 .cellular 一致）：**
```zig
-- 应用在 Bus(input_spec, output_spec, ChannelFactory) 的 input_spec 中定义 .cellular = CellularPayload。
-- 创建 Cellular 时传入 rt.bus.Injector(.cellular)，Cellular 内部仅调用 injector.invoke(payload)。

pub const CellularPayload = union(enum) {
    phase_changed: struct { from: CellularPhase, to: CellularPhase },
    signal_updated: CellularSignalInfo,
    sim_status_changed: SimStatus,
    registration_changed: CellularRegStatus,
    error: ModemError,
};
```

### 5.8.1 CellularControl（Phase 1，参考 BLE Host）

**参考：** `pkg/ble/host/host.zig` — 用户通过 Host 的 API（如 requestDataLength、gattRead）入队到 tx_queue，readLoop/writeLoop 独占 HCI 并回写 response；GATT Client 的 read/write 阻塞在 `conn.att_response.recv()` 等待结果。Cellular 采用同样思路：**用户只持 CellularControl handle，请求入队，worker 在 tick 间隙执行并写回 response；用户请求的 timeout 仅作用于该次调用，不喂给 reducer（见 6.1.1）。**

**职责划分：**

| 角色 | 职责 |
|------|------|
| **Cellular（Runner）** | 持有 Modem、injector、state、request_queue、response_channel；worker 循环：tick()（生命周期）→ 若有 Control 请求则处理 → 写 response；**仅**生命周期路径的 AT 结果驱动 reduce/emitIfChanged。 |
| **CellularControl** | 用户侧 handle，持有 request_queue 的发送端与 response_channel 的接收端；提供 getSignalQuality(timeout_ms)、send(comptime Cmd, cmd, timeout_ms) 等；调用时入队请求并阻塞/ timedRecv 等结果，超时则向**调用方**返回 Err(Timeout)，不触碰 reducer。 |

**类型与通道（types.zig 或 cellular.zig 内）：**

- **AtError（方案 A）**：不单独定义枚举；`ControlResponse.at_error` 携带 **AtStatus**（或仅失败子集：timeout / error / cme_error / cms_error / overflow）。Worker 将 `at().send()` 的非 ok 结果写入 `.at_error = that_status`。CellularControl 的公开 API 收到 `.at_error` 时统一返回 **error.AtError**（或按需 error.Timeout），不向调用方暴露 AtStatus 各变体；便于日志/调试时仍可读 response 内的 status。

- **SendAtPayload（buf+len，防越界）**：固定容量 + 有效长度，Phase 1 不做 type-erased 执行体。
  - 定义：`SendAtPayload = struct { buf: [SEND_AT_BUF_CAP]u8, len: usize }`，常量 `SEND_AT_BUF_CAP = 256`（与 at/engine.zig 内 cmd_buf 一致；若后续有更长命令可改为 512 并统一）。
  - **不变式**：`len <= SEND_AT_BUF_CAP`。调用方（`control.send(Cmd, cmd, timeout_ms)`）在序列化后若 `serialized_len > SEND_AT_BUF_CAP`，**不得**入队，直接向调用方返回 **error.PayloadTooLong**，不写入 request_queue。Worker 只使用 `payload.buf[0..payload.len]` 调用 `sendRaw`；实现时可做防御性检查 `if (payload.len > payload.buf.len) { 回写 .at_error 或专用错误；return }`，保证不会数组越界。

```zig
// 请求
pub const SEND_AT_BUF_CAP = 256;
pub const SendAtPayload = struct {
    buf: [SEND_AT_BUF_CAP]u8,
    len: usize,  // 有效字节数，必须 <= buf.len
};

pub const ControlRequestTag = enum { get_signal_quality, send_at };
pub const ControlRequest = union(ControlRequestTag) {
    get_signal_quality: void,
    send_at: SendAtPayload,
};

// 响应：at_error 携带 AtStatus（方案 A）
pub const ControlResponse = union(enum) {
    signal_quality: CellularSignalInfo,
    at_ok: void,
    at_error: AtStatus,   // 失败时的 AT 状态（timeout/error/cme_error/cms_error/overflow）
    timeout: void,
    uninitialized: void,
};
```

**Cellular 新增字段与 init：**

- `request_queue`：单生产者单消费者队列，容量 4～8。由 **runtime/channel_factory**（与 Bus 相同）生成：`ChannelFactory.Channel(ControlRequest).init(allocator, 4)`（或 8），ChannelFactory 通过 `embed.runtime.ChannelFactory` / `embed.runtime.std.ChannelFactory` 取得。
- `response_channel`：**单槽**（与 BLE Host 的 ResponseSlot 单槽语义一致）。类型 `ChannelFactory.Channel(ControlResponse)`；capacity 0（无缓冲 rendezvous）或 1（单槽缓冲，worker 可非阻塞 send）由实现择一。worker 完成一次 Control 请求后写入一条，Control 侧 recv/timedRecv。
- `control_handle`: 持有对 request_queue 的 send 端与 response_channel 的 recv 端的引用；由 `Cellular.control()` 返回，或 init 时一并创建并暴露。

**CellularControl API（可操作规格）：**

| 方法 | 签名（示例） | 行为 |
|------|---------------------|------|
| `getSignalQuality` | `getSignalQuality(self: *CellularControl, timeout_ms: u32) !CellularSignalInfo` | 若当前 phase 为 off 或未就绪，直接返回 `error.Uninitialized`（或先入队，worker 回 uninitialized）。否则 request_queue.send(.get_signal_quality)，再 response_channel.timedRecv(timeout_ms)；若收到 .signal_quality 则返回，若 .timeout/.at_error 则返回 error.Timeout / error.AtError，**不**调用 reduce。 |
| `send`（泛型 AT） | `send(self: *CellularControl, comptime Cmd: type, cmd: Cmd, timeout_ms: u32) !Cmd.Response` | 序列化 Cmd 到 SendAtPayload.buf；若 `serialized_len > SEND_AT_BUF_CAP` 则直接返回 **error.PayloadTooLong** 不入队。否则入队 .send_at(payload)，worker 用 payload.buf[0..payload.len] 调 sendRaw，结果写入 response；超时或 AT 错误仅作为该次调用的错误返回，不送 reducer。 |
| `getState`（只读） | `getState(self: *const CellularControl) ModemState` 或返回 phase/signal 等只读视图 | **不**发请求，直接读 Cellular 内部 state 的当前快照（可加锁或原子读），无 timeout、无 reducer 交互。 |

**Worker 内处理 Control 请求（与 tick 生命周期隔离）：**

```
在 workerMain 循环内，每次 tick() 之后（或之前，视实现而定）：
  1. 若 request_queue.tryRecv() 得到请求 req：
     a. 若 state.phase == .off（或约定不可用）：response_channel.send(.uninitialized)；continue。
     b. switch (req)：
        - .get_signal_quality：调用 signal.getStrength()，成功则 response.send(.signal_quality, info)，失败则 response.send(.at_error = status 或 .timeout)，**不**调用 reduce，**不**增加 at_timeout_count。
        - .send_at：仅使用 payload.buf[0..payload.len] 调 at.sendRaw(...)；若 payload.len > buf.len 则防御性回写 .at_error；否则将 sendRaw 结果写入 response，同上，不送 reducer。
  2. 若对单次请求需要超时控制，仅在 worker 内对该次 at().send() 使用 timeout；超时后只 response.send(.timeout)，不派发任何 ModemEvent。
```

**参考 BLE 的要点：**

- BLE：tx_queue.send() → writeLoop 发送；att_response.recv() 阻塞等响应。Cellular：request_queue.send() → worker 执行 → response_channel.send()；control.getSignalQuality() 内 timedRecv(timeout_ms)。
- BLE 的 GATT 读/写是「一发一收」；Cellular 同样「一个请求一个 response」，可约定同一时刻仅允许一个 in-flight Control 请求（简化实现），或使用 request_id 配对多条 response。

**测试与验证（见 Step 11 与 8.10）：**

- 单测：CT-01 生命周期路径连续 at_timeout 仍使 at_timeout_count 增至 3 并进入 error。
- 单测：CT-02 Control.getSignalQuality() 超时多次（或故意让 worker 回 .timeout），state.phase 不变、at_timeout_count 不增加。
- 单测：CT-03 phase == .ready 时 getSignalQuality() 返回有效 CellularSignalInfo；phase == .off 时返回 Uninitialized。

### 5.9 modem/sim.zig

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

### 5.10 modem/signal.zig

Signal quality monitoring. Sends AT commands via AtEngine.

```zig
pub const Signal = struct {
    at: *AtEngine,

    pub fn init(at_engine: *AtEngine) Signal;
    pub fn getStrength(self: *Signal) !CellularSignalInfo;
    pub fn getRegistration(self: *Signal) !CellularRegStatus;
    pub fn getNetworkType(self: *Signal) !RAT;
};
```

### 5.11 modem/profiles/quectel.zig & modem/profiles/simcom.zig

Module-specific command/URC/init-sequence namespaces. Each file exports a
standard set of declarations that `Modem(comptime Module)` consumes at comptime.

**Module namespace contract** (duck-typed, checked by Modem at comptime):

| Export | Type | Description |
|---|---|---|
| `commands` | namespace | Module-specific AT command structs (same contract as 5.4) |
| `urcs` | namespace | Module-specific URC structs (same contract as at/urcs.zig) |
| `init_sequence` | `[]const type` | Ordered list of command types for module initialization |

```zig
-- modem/profiles/quectel.zig
const base_cmds = @import("../at/commands.zig");
const types = @import("../types.zig");

pub const commands = struct {
    pub const SetNetworkCategory = struct {
        pub const Response = void;
        pub const prefix = "";
        pub const timeout_ms: u32 = 5000;
        pub fn write(buf: []u8) usize { ... }
        pub fn parseResponse(_: []const u8) ?Response { return {}; }
    };
    pub const GetModuleInfo = struct {
        pub const Response = types.ModemInfo;
        pub const prefix = "+QGMR";
        pub const timeout_ms: u32 = 3000;
        pub fn write(buf: []u8) usize { ... }
        pub fn parseResponse(line: []const u8) ?Response { ... }
    };
};

pub const urcs = struct {
    pub const PowerDown = struct {
        pub const Payload = void;
        pub const prefix = "POWERED DOWN";
        pub fn parseUrc(_: []const u8) ?Payload { return {}; }
    };
};

pub const init_sequence = &[_]type{
    base_cmds.Probe,
    commands.SetNetworkCategory,
    base_cmds.GetSimStatus,
    base_cmds.GetRegistration,
};
```

```zig
-- Modem consumes Module at comptime
pub fn Modem(comptime Thread: type, comptime Time: type, comptime Module: type) type {
    return struct {
        comptime {
            _ = Module.commands;
            _ = Module.urcs;
            _ = Module.init_sequence;
        }
        -- ...uses Module.init_sequence in runInit(), Module.urcs in pumpUrcs()
    };
}
```

### 5.12 voice.zig (phase 2)

```zig
pub const Voice = struct {
    at: *AtEngine,
    pub fn init(at_engine: *AtEngine) Voice;
    pub fn dial(self: *Voice, number: []const u8) !void;
    pub fn answer(self: *Voice) !void;
    pub fn hangup(self: *Voice) !void;
    pub fn getCallState(self: *Voice) !VoiceCallState;
    pub fn registerUrcs(self: *Voice, dispatch_ctx: anytype) void;
};
```

### 5.13 apn.zig (phase 2)

```zig
pub fn resolve(imsi: []const u8) ?[]const u8;
```

---

## 6. Reducer

Pure function, lives inside `Cellular` (not `Modem`). All state transitions centralized here.
Cellular.tick() infers ModemEvent from hardware queries, then calls reduce() to drive state.

### 6.1 错误类型与重试/超时（状态机内驱动）

**原则：** 重试与超时在状态机内部通过计数/阈值处理；**只有达到重试次数或超时条件后**，才进入 `error` 并设置 `error_reason`，此时向 Flux 发送 `CellularEvent.error(ModemError)`。在此之前不向应用层抛错。

**统一错误类型（types.zig）：**

```zig
pub const ModemError = enum {
    at_timeout,          // 连续 AT 超时达到阈值（如 3 次）
    at_fatal,            // AT 通道不可用
    sim_not_inserted,
    sim_pin_required,
    sim_error,           // 其它 SIM 错误
    cmux_failed,         // enterCmux 失败
    registration_denied,
    registration_failed,
    ppp_failed,          // 拨号/PPP 失败（可选：N 次后才进 error）
    config_failed,       // 配置命令失败；reducer 可忽略（对齐 C）
};
```

**ModemState 新增字段：**

| 字段 | 类型 | 含义 |
|------|------|------|
| `error_reason` | `?ModemError` | 进入 error 时的原因；`retry` / `power_on` 时清空 |
| `at_timeout_count` | `u8` | 生命周期 AT 超时计数（当前实现：`at_timeout` 事件即进 error 并递增）；`power_on` / `retry` 清零 |

**Reducer 与 tick（R44，以 `src/pkg/cellular/cellular.zig` 为准）：**

| 当前 phase | 典型 ModemEvent（tick 或应用 dispatch） | 下一 phase / 说明 |
|------------|----------------------------------------|---------------------|
| off | power_on | probing |
| probing | bootstrap_probe_ok | at_configuring；bootstrap_at_error / at_timeout → error |
| at_configuring | bootstrap_echo_ok → bootstrap_cmee_ok | checking_sim |
| checking_sim | sim_status_reported(ready) | registering；PIN/未插卡 → error |
| registering | network_registration(home/roam) | registered；searching 等 → 仍 registering，tick 继续 CEREG；denied → error |
| registered | dial_requested | dialing |
| dialing | dial_succeeded / ip_obtained | connected；dial_failed → registered |
| connected | ip_lost | registered |
| error | retry | probing，清空 error_reason、at_timeout_count |

**Cellular.tick()：** 仅在与 bootstrap 相关的 phase 发一条 AT，将结果 dispatch 为 **具名结果事件**（如 `bootstrap_probe_ok`、`sim_status_reported`），**不得**再使用 `at_ready` / `sim_ready` 等旧事件名。

**与 C (quectel) 对照：** PPP 失败回退 registered；error + retry 回到探活（probing）软恢复。

#### 6.1.1 Control 请求与生命周期隔离（R37 硬性约束）

**目的：** 用户通过 CellularControl 发起的请求（如 getSignalQuality、send(Cmd)）与状态机生命周期共用同一 AT 通道，但**在错误/超时语义上必须隔离**，避免一次用户请求超时导致模组被误判为故障并进入 error。

**约束（实现时必须遵守）：**

1. **仅生命周期路径驱动 reducer**  
   只有 tick() 内生命周期 AT（probing / at_configuring / checking_sim / registering 等）产生的失败才可 dispatch 为 `bootstrap_at_error`、`at_timeout` 等并 reduce()。**任何** Control 请求的 AT **不得** dispatch 为上述 ModemEvent，**不得**改 phase。

2. **用户请求的 timeout 仅作用于该次请求**  
   Control 侧 API 的 timeout_ms 仅用于：  
   - 调用方在 response channel 上 timedRecv(timeout_ms)，超时则向**调用方**返回 Err(Timeout)；  
   - 可选：worker 执行该请求时若超过 timeout_ms 未完成，可放弃并向 response 发送「超时」结果，同样仅由调用方收到，不触发 reducer。  
   无论哪种，**均不**向 reducer 派发任何 `ModemEvent`。

3. **实现检查清单**  
   - Worker 中区分「本周期是生命周期 tick」与「处理 Control 请求」：处理 Control 请求时调用的 at().send() 等，其错误/超时只写入 response channel，不调用 reduce()。  
   - 若 worker 内对 Control 请求做超时（例如带超时的 at().send()），超时后只 response_queue.send(.timeout)，不派发 ModemEvent。  
   - 单测中显式验证：仅生命周期路径的连续 at_timeout 会使 at_timeout_count 增加并最终进 error；Control.getSignalQuality() 超时多次不改变 phase、不增加 at_timeout_count。

```
// 权威实现：src/pkg/cellular/cellular.zig — pub fn cellularReduce(s: *CellularFsmState, e: ModemEvent) void
// 状态为 CellularFsmState { modem: ModemState, bootstrap_step: InitSequenceStep }
// 勿使用已废弃事件名：at_ready, sim_ready, dial_start, dial_connected, registration_failed（ModemEvent 字段）
```

---

## 7. Usage Examples

### 7.1 ESP32 (UART, single-channel, with Bus integration)

**应用侧：** App 的 InputSpec 需包含 `.cellular = cellular.CellularPayload`，以便 Bus 生成对应 InputEvent 与 Injector。

```
const cellular = @import("embed").pkg.cellular;
const quectel = cellular.modem.quectel;
const EspGpio = hal.gpio.from(.{ .Driver = esp_gpio.Driver, .meta = .{ .id = "esp-gpio" } });
const CellPeripheral = cellular.Cellular(EspThread, EspNotify, EspTime, quectel, EspGpio, 1024);

-- 创建 Cellular：传入 modem 配置、injector（由 rt.bus.Injector(.cellular) 取得）、config
const uart_io = io.fromUart(UartDriver, &uart_driver);
const injector = rt.bus.Injector(.cellular);
var gpio_driver: esp_gpio.Driver = .{};
var gpio = EspGpio.init(&gpio_driver);
var cell = try CellPeripheral.init(allocator, .{
    .io = uart_io,
    .time = board.time,
    .gpio = &gpio,
    .pins = .{ .power_pin = MODEM_ENABLE_PIN, .vint_pin = VINT_PIN },
}, injector, .{ .poll_interval_ms = 1000 });

-- 无需 bus.register(channel)；injector 已将推事件路径绑定到 Bus
try cell.start();

-- 主循环：从 Bus 收事件并 dispatch，再根据 state 驱动 UI/输出
while (true) {
    const r = try rt.recv();
    if (!r.ok) break;
    rt.dispatch(r.value);
    if (rt.isDirty()) { ... render ...; rt.commitFrame(); }
}

cell.stop();
```

### 7.2 Linux (USB, multi-channel)

```
const MockGpio = hal.gpio.from(.{ .Driver = mock_gpio.Driver, .meta = .{ .id = "mock-gpio" } });
const CellPeripheral = cellular.Cellular(StdThread, StdNotify, StdTime, quectel, MockGpio, 1024);

const at_io = linux_serial.open("/dev/ttyUSB1");
const data_io = linux_serial.open("/dev/ttyUSB0");
const injector = rt.bus.Injector(.cellular);
var cell = try CellPeripheral.init(allocator, .{
    .at_io = at_io,
    .data_io = data_io,
    .time = StdTime{},
    .gpio = null,     -- USB multi-channel: no GPIO pin control
}, injector, .{});

-- Two Io provided -> Modem uses multi-channel mode, no CMUX
try cell.start();
-- 主循环同 7.1：rt.recv() → rt.dispatch() → isDirty() → render
```

### 7.3 Test (mock)

测试时需提供 injector：可将 Bus 的 `Injector(.cellular)` 传入，或构造一个**测试用 injector**（例如把收到的 payload 写入测试用的 channel（由 ChannelFactory 生成）/队列），再在测试里从该队列 recv 做断言。

```
const MockGpioT = hal.gpio.from(.{ .Driver = mock_gpio.Driver, .meta = .{ .id = "test-gpio" } });
const TestCellular = cellular.Cellular(StdThread, StdNotify, FakeTime, quectel, MockGpioT, 512);

-- 方式 A：使用真实 Bus，主线程 rt.recv() 收事件后断言
const injector = test_bus.Injector(.cellular);
var cell = try TestCellular.init(allocator, modem_cfg, injector, .{});
mock_at.feed("+CPIN: READY\r\nOK\r\n");
cell.tick();
const r = try test_bus.recv();  -- 从 Bus 收事件（Bus 已 use 了 cellular 的 inject 源）
-- 断言 r.value 为 .input => .cellular => .phase_changed 等

-- 方式 B：测试用 injector，将 payload 写入 test_channel，便于单测不依赖完整 Bus
var test_channel = try TestChannel.init(allocator, 8);
const test_injector = EventInjector(CellularPayload){ .ctx = &test_channel, .call = testInjectCellular };
var cell = try TestCellular.init(allocator, modem_cfg, test_injector, .{});
cell.tick();
const event = try test_channel.recv();  -- event == CellularPayload (e.g. .phase_changed)
```

### 7.4 Modem-only usage (without Cellular/Bus)

For low-level access or custom orchestration, Modem can be used directly:

```
const quectel = @import("cellular/modem/profiles/quectel.zig");
const MockGpio = hal.gpio.from(.{ .Driver = mock_gpio.Driver, .meta = .{ .id = "mock-gpio" } });
const CellModem = cellular.Modem(StdThread, StdNotify, StdTime, quectel, MockGpio, 1024);

var modem = CellModem.init(.{ .io = uart_io, .time = board.time, .gpio = null });
const result = modem.at().send(quectel.commands.GetModuleInfo, .{});
-- Manual control, no state machine, no channel
-- Module-specific commands available via quectel.commands namespace
```

---

## 8. Test Plan

### 8.1 io/mock.zig — MockIo

The universal test transport. Simulates any channel (UART, USB port, CMUX virtual channel).
采用**两段线性 buffer**（与 pkg/net/ws、pkg/net/tls 的 MockConn 风格一致），无 RingBuffer 依赖。

**存储与语义：**

- **发端 (tx)**：`tx_buf: [capacity]u8`，`tx_len: usize`。`Io.write()` 将数据追加到 tx_buf，受 capacity 限制；`sent()` 返回 `tx_buf[0..tx_len]`；`drain()` 将 `tx_len` 置 0。
- **收端 (rx)**：`rx_buf: [capacity]u8`，`rx_len: usize`，`rx_pos: usize`。测试侧调用 `feed(bytes)` 注入响应（拷贝入 rx_buf、设 `rx_len = bytes.len`、`rx_pos = 0`）；`Io.read()` 从 `rx_buf[rx_pos..rx_len]` 拷贝到调用方并推进 `rx_pos`；当 `rx_pos >= rx_len` 时无数据可读，`read()` 返回 `WouldBlock`。
- **capacity**：建议 1024（与 plan 原 1024 一致），可由 `init(comptime capacity)` 或常量在 mock.zig 内固定。

```
MockIo(capacity):
    tx_buf: [capacity]u8
    tx_len:  usize = 0
    rx_buf:  [capacity]u8
    rx_len:  usize = 0
    rx_pos:  usize = 0

    pub fn init(comptime capacity: usize) MockIo(capacity);   -- 或 init() 使用默认 1024
    pub fn io(self: *MockIo) Io;                              -- returns Io backed by this mock

    -- Test helpers
    pub fn feed(self: *MockIo, bytes: []const u8) void;      -- inject response into rx (copy to rx_buf, rx_len=len, rx_pos=0)
    pub fn sent(self: *MockIo) []const u8;                   -- tx_buf[0..tx_len], what was written
    pub fn drain(self: *MockIo) void;                        -- clear tx (tx_len = 0)

    -- Sequence helper (R41): pre-fill a series of responses for multi-step flows
    pub fn feedSequence(self: *MockIo, responses: []const []const u8) void;
    -- e.g. feedSequence(&.{ "OK\r\n", "+CPIN: READY\r\nOK\r\n", "+CSQ: 20,0\r\nOK\r\n" })
    -- Appends all responses into rx_buf sequentially. Each tick reads one response worth of data.
```

**R41 修正：移除 onSend() 自动应答，只保留 FIFO feed()。**

理由：
- tick() 改为按 phase 每次只发一条 AT（对齐 quectel C / ublox-rs / Zephyr），FIFO feed 即可覆盖所有场景
- BLE `MockHci` 也只有 `injectPacket` 无自动应答，已验证可行
- 复杂流程用 `feedSequence()` 一次性预填多步响应（类比 BLE `injectInitSequence()`）
- 测试代码更简单直观：按 tick 顺序 feed 对应响应，无需理解匹配规则

### 8.2 types_test.zig (3 tests)

| ID    | Test | Validates |
|-------|------|-----------|
| TY-01 | ModemState default | phase=.off, sim=.not_inserted |
| TY-02 | ModemInfo getters | getImei/getModel/getFirmware slice correctness |
| TY-03 | SimInfo getters | getImsi/getIccid slice correctness |

### 8.3 io/io_test.zig (3 tests)

| ID    | Test | Validates |
|-------|------|-----------|
| IO-01 | Io round-trip | write bytes -> read bytes through mock-backed Io |
| IO-02 | fromUart | UART HAL wrapped as Io, read/write pass through |
| IO-03 | WouldBlock | empty read returns WouldBlock |

### 8.3.1 io/trace_test.zig (4 tests, R29)

| ID    | Test | Validates |
|-------|------|-----------|
| TR-01 | trace write | wrap(mock).write("AT\r") -> log_fn called with (.tx, "AT\r") |
| TR-02 | trace read | wrap(mock).read() -> log_fn called with (.rx, data) |
| TR-03 | trace passthrough | data passes through unmodified to inner Io |
| TR-04 | trace poll | poll delegates to inner, no log call |

### 8.4 at/parse_test.zig (11 tests)

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

### 8.5 at/commands_test.zig (8 tests)

| ID    | Test | Validates |
|-------|------|-----------|
| AC-01 | GetSignalQuality write | write() produces "AT+CSQ\r" |
| AC-02 | GetSignalQuality parse | parseResponse("+CSQ: 20,0") -> CellularSignalInfo{rssi=-73} |
| AC-03 | GetSimStatus write | write() produces "AT+CPIN?\r" |
| AC-04 | GetSimStatus parse | parseResponse("+CPIN: READY") -> .ready |
| AC-05 | EnterPin write | .{.pin="1234"}.write() produces "AT+CPIN=1234\r" |
| AC-06 | GetRegistration parse | parseResponse("+CGREG: 0,1") -> .registered_home |
| AC-07 | comptime contract | Cmd without Response -> compile error (comptime test) |
| AC-08 | typed send round-trip | MockIo + engine.send(GetSignalQuality, .{}) -> typed result |

### 8.6 at/engine_test.zig (11 tests, uses MockIo)

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

### 8.7 at/cmux_test.zig (10 tests, uses MockIo)

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

### 8.7.1 at/urcs_test.zig (5 tests, R29)

| ID    | Test | Validates |
|-------|------|-----------|
| UC-01 | NetworkRegistrationUrc parse | "+CREG: 0,1" -> .registered_home |
| UC-02 | SimHotplugUrc parse | "+QSIMSTAT: 1,1" -> sim_inserted=true |
| UC-03 | RingUrc parse | "+CRING: VOICE" -> void payload |
| UC-04 | prefix mismatch | wrong prefix -> null (no match) |
| UC-05 | pumpUrcsTyped dispatch | feed multiple URCs -> correct typed callbacks |

### 8.8 modem/modem_test.zig (13 tests, no state machine)

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

### 8.9 cellular_test.zig — R44 状态机（`zig build test-cellular`）

规格用例与 **ModemEvent / CellularPhase** 对应（旧名 `at_ready`、`sim_ready`、`dial_start`、`dial_connected` 已删除）：

| ID | 事件序列（节选） | 结果 phase |
|----|------------------|------------|
| CR-01 | `power_on` | `probing` |
| CR-02 | `bootstrap_probe_ok` | `at_configuring` |
| CR-03 | `bootstrap_echo_ok` → `bootstrap_cmee_ok` | `checking_sim` |
| CR-04 | `sim_status_reported(.ready)` | `registering` |
| CR-05 | `network_registration(.registered_home)` 等 | `registered` |
| CR-06 | `sim_status_reported(.pin_required)` 等 | `error` |
| CR-07 | `network_registration(.searching)` 等 | 保持 `registering`，`bootstrap_step=done`，继续轮询 CEREG |
| CR-08 | `network_registration(.denied)` | `error` / `registration_denied` |
| CR-09 | `bootstrap_at_error` / `at_timeout` | `error` |
| CR-10 | `dial_requested`（自 `registered`） | `dialing` |
| CR-11 | `dial_succeeded` / `ip_obtained` | `connected` |
| CR-12 | `dial_failed` | `registered` |
| CR-13 | `ip_lost`（自 `connected`） | `registered` |
| CR-14 | `retry`（自 `error`） | `probing`，`at_timeout_count=0` |
| CR-15 | `signal_updated` | 仅更新 signal |
| CR-16 | `power_off` | `off` |

集成路径：`tick()` + MockIo 或 `applyModemEvents` 种子 + `tick`。SIM 热插拔等未实现事件不在上表。

### 8.10 cellular_test.zig — event emission (7) + Control (3) tests

测试时向 Cellular.init 传入**测试用 injector**（如将 payload 写入 test channel，见 7.3 方式 B），再对收到的 payload 做断言。不再使用 cell.channel.recv()，改为从测试 injector 绑定的 channel 或 Bus.recv() 取事件。

**事件发射（CE-01～CE-07）：**

| ID    | Test | Validates |
|-------|------|-----------|
| CE-01 | phase change emits event | tick() 检测到 phase 变化 → injector.invoke(phase_changed) 被调用，测试 channel 收到对应 payload |
| CE-02 | signal update emits event | 信号变化 → injector.invoke(signal_updated) |
| CE-03 | sim status change emits event | sim removed → injector.invoke(sim_status_changed) |
| CE-04 | no change no event | tick() 状态不变 → 无 invoke 调用 |
| CE-05 | start/stop lifecycle | start() 启动线程，stop() 正常 join |
| CE-06 | injector integration | tick() 后从测试 injector 绑定的 channel（或 Bus.recv()）能收到对应 CellularPayload |
| CE-07 | error emits event | AT 超时达到阈值 → injector.invoke(error) |

**Control 与生命周期隔离（CT-01～CT-03，R37/6.1.1）：**

| ID    | Test | Validates |
|-------|------|-----------|
| CT-01 | lifecycle at_timeout → error | **仅**生命周期路径：Mock 使 tick() 连续得到 at_timeout，断言 at_timeout_count 增至 3 后 phase=error、error_reason=at_timeout |
| CT-02 | control timeout 不干扰 reducer | 多次调用 control.getSignalQuality(timeout_ms) 且让 worker 回 .timeout 或调用方 timedRecv 超时；断言 state.phase、at_timeout_count 不变，无 injector.invoke(error) |
| CT-03 | control 按需查询 | phase == .ready 时 getSignalQuality(5000) 返回有效 CellularSignalInfo；phase == .off 时返回 error.Uninitialized；可选 send(Cmd) 返回 OK |

### 8.11 modem/sim_test.zig (7 tests)

| ID    | Test | Validates |
|-------|------|-----------|
| SM-01 | SIM ready | AT+CPIN? -> "+CPIN: READY" -> .ready |
| SM-02 | not inserted | -> "+CME ERROR: 10" -> .not_inserted |
| SM-03 | PIN required | -> "+CPIN: SIM PIN" -> .pin_required |
| SM-04 | IMSI | AT+CIMI -> "460001234567890" |
| SM-05 | ICCID | AT+QCCID -> "+QCCID: 89860..." |
| SM-06 | hotplug URC | "+QSIMSTAT: 0,0" -> removal |
| SM-07 | PIN entry | "AT+CPIN=1234\r" sent -> OK |

### 8.12 modem/signal_test.zig (7 tests)

| ID    | Test | Validates |
|-------|------|-----------|
| SG-01 | CSQ | "+CSQ: 20,0" -> rssi=-73 |
| SG-02 | no signal | "+CSQ: 99,99" -> null |
| SG-03 | LTE quality | AT+QCSQ -> rsrp/rsrq |
| SG-04 | reg home | "+CGREG: 0,1" -> registered_home |
| SG-05 | reg roaming | "+CEREG: 0,5" -> registered_roaming |
| SG-06 | reg denied | "+CGREG: 0,3" -> denied |
| SG-07 | network type | AT+QNWINFO -> .lte |

### 8.13 modem/profiles/quectel_test.zig (4 tests, R31)

| ID    | Test | Validates |
|-------|------|-----------|
| QC-01 | Quectel command write | SetNetworkCategory.write() produces correct bytes |
| QC-02 | Quectel command parse | GetModuleInfo.parseResponse() parses Quectel format |
| QC-03 | Quectel URC parse | PowerDown.parseUrc("POWERED DOWN") -> .{} |
| QC-04 | init_sequence order | init_sequence contains expected command types in order |

### 8.14 modem/profiles/simcom_test.zig (4 tests, R31)

| ID    | Test | Validates |
|-------|------|-----------|
| SC-01 | SIMCom command write | module-specific command produces correct bytes |
| SC-02 | SIMCom command parse | module-specific response parsed correctly |
| SC-03 | SIMCom URC parse | module-specific URC parsed correctly |
| SC-04 | init_sequence order | init_sequence contains expected command types in order |

**Total: 121 test cases** (110 from R29 + 4 quectel + 4 simcom from R31 + 3 Control from R37)

---

## 9. Implementation Plan (Step-by-Step)

### 验证方式说明

每一步开发完成后必须验证。验证分两种方式：

| 方式 | 说明 | 适用场景 |
|------|------|----------|
| **烧录验证** | 编译固件烧录到 ESP32S3，通过 UART 连接真实 4G 模组，串口 log 输出结果 | 涉及 IO 交互的所有步骤 |
| **Mock 验证** | 在开发机上运行 `zig build test`（在 `test/unit/` 目录下），用 MockIo（两段线性 buffer）模拟通道。测试文件位于 `test/unit/pkg/cellular/`，通过 `@import("embed")` 访问库代码 | 纯类型定义、纯函数、纯状态机逻辑 |

**原则：能烧录验证就烧录验证。只有完全没有硬件交互的纯计算逻辑才用 Mock。**

### 实施约束（R39）

1. **与 main 的关系**：cellular 包的功能独立于 main（不依赖 main 的 lwIP 重构等），但 runtime、sync、channel_factory、thread、time 等基础组件依赖 main 最新版本；开发时需同步 main 以获取这些依赖。
2. **真机验证**：有真机时，所有可在真机上运行的步骤必须在真机上运行并通过验证后，才能进入下一步开发；不得跳过烧录验证。

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
| `test/unit/pkg/cellular/types_test.zig` | 新建 | 类型单元测试 |
| `src/pkg/cellular/io/` | 创建目录 | io 子包 |
| `src/pkg/cellular/at/` | 创建目录 | at 子包 |
| `src/pkg/cellular/modem/` | 创建目录 | modem 子包 |

**实现内容：**
- CellularPhase（R44：`probing` / `at_configuring` / `checking_sim` / `registering` / …）
- SimStatus / RAT / CellularRegStatus / VoiceCallState
- ModemState、ModemEvent（bootstrap_*、`sim_status_reported`、`network_registration`、`dial_requested` 等，**无** `at_ready`/`sim_ready`/`dial_start`）
- APNConfig / CmuxChannelRole / CmuxChannelConfig / ModemConfig 结构体

**测试命令：**

```bash
cd test/unit && zig build test
```

**测试用例（3 个）：**

| ID | 测试名 | 验证内容 |
|----|--------|----------|
| TY-01 | ModemState default | `phase == .off`, `sim == .not_inserted` |
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
| `src/pkg/cellular/io/io.zig` | 新建 | Io 接口 + fromUart/fromSpi |
| `src/pkg/cellular/io/mock.zig` | 新建 | MockIo（两段线性 buffer） |
| `test/unit/pkg/cellular/io/io_test.zig` | 新建 | Io 接口单元测试 |
| `test/firmware/110-cellular/app.zig` | 修改 | 追加 Io 透传验证逻辑 |

**实现内容：**
- `Io` 结构体（ctx + readFn + writeFn，type-erased）
- `Io.read()` / `Io.write()` 方法
- `fromUart(comptime UartType, *UartType) Io` — 将 UART HAL 包装为 Io
- `fromSpi(comptime SpiType, *SpiType) Io` — 将 SPI HAL 包装为 Io
- `MockIo` — 测试用，基于两段线性 buffer（tx_buf/tx_len、rx_buf/rx_len/rx_pos）的 Io 实现
  - `init()` / `io()` / `feed()` / `feedSequence()` / `sent()` / `drain()`

**Mock 测试命令：**

```bash
cd test/unit && zig build test
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

### Step 3: parse.zig — AT 响应解析（纯函数）

**目标：** 实现 AT 响应的纯解析函数，无状态、无 IO。

**验证方式：Mock 验证 + 可选烧录验证**

**理由：** parse.zig 是纯函数集合，输入字符串输出解析结果，Mock 即可覆盖核心逻辑。
但不同模组返回的响应格式可能有细微差异（多余空格、换行符等），
建议在真机上用模组的真实响应跑一遍解析函数，验证格式兼容性。

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/pkg/cellular/at/parse.zig` | 新建 | 纯解析函数 |
| `test/unit/pkg/cellular/at/parse_test.zig` | 新建 | AT 解析单元测试 |

**实现内容：**
- `isOk(line)` — 判断是否为 "OK"
- `isError(line)` — 判断是否为 "ERROR"
- `parseCmeError(line)` — 解析 "+CME ERROR: N" → N
- `parseCmsError(line)` — 解析 "+CMS ERROR: N" → N
- `parsePrefix(line, prefix)` — 提取前缀后的值（如 "+CSQ: 20,0" → "20,0"）
- `parseCsq(value)` — 解析 CSQ 值为 CellularSignalInfo
- `parseCpin(value)` — 解析 CPIN 值为 SimStatus
- `parseCreg(value)` — 解析 CREG/CGREG/CEREG 值为 CellularRegStatus
- `rssiToDbm(csq)` — CSQ 值转 dBm
- `rssiToPercent(dbm)` — dBm 转百分比

**测试命令：**

```bash
cd test/unit && zig build test
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
2. 将原始响应逐行传给 parse 模块的解析函数验证：
   [I] === Step 3: parse real-device test ===
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

### Step 4: engine.zig + commands.zig — AT 指令引擎（核心里程碑 #1）

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
| `src/pkg/cellular/at/engine.zig` | 新建 | AT 指令引擎 |
| `src/pkg/cellular/at/commands.zig` | 新建 | AT 命令类型定义（R28） |
| `test/unit/pkg/cellular/at/engine_test.zig` | 新建 | AT 引擎单元测试 |
| `test/unit/pkg/cellular/at/commands_test.zig` | 新建 | AT 命令类型测试（R28） |
| `test/firmware/110-cellular/app.zig` | 修改 | 追加 AT 引擎验证逻辑 |

**实现内容：**
- `AtStatus` 枚举（ok/error/cme_error/cms_error/timeout/overflow）
- `AtEngine(comptime Time, comptime buf_size)` — 单一平坦缓冲区，大小由 comptime 控制（R39）
- `AtResponse` 结构体（status + body 切片 + error_code + lineIterator）— 内嵌于 AtEngine，body 指向 rx_buf 内切片
- `UrcHandler` 结构体（prefix + callback）
- `AtEngine` 方法：
  - `init(io: Io, time: Time) Self`
  - `setIo(io: Io) void` — 运行时切换底层 Io（CMUX 切换时用）
  - `sendRaw(cmd, timeout_ms) AtResponse` — 低级发送（原始字节）
  - `send(comptime Cmd, cmd) SendResult(Cmd)` — 泛型发送（R28，编译期类型校验）
  - `registerUrc(prefix, handler) bool` — 注册 URC 处理器
  - `unregisterUrc(prefix) void`
  - `pumpUrcs() void` — 轮询并分发 URC
- `commands.zig`（R28）— AT 命令类型定义，详见 Section 5.4

**Mock 测试命令：**

```bash
cd test/unit && zig build test
```

**Mock 测试用例（19 个，含 8 个 commands 测试）：**

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

**commands_test.zig 测试用例（8 个，R26）：**

见 Section 8.5 at/commands_test.zig。

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
| `src/pkg/cellular/modem/sim.zig` | 新建 | SIM 卡管理 |
| `test/unit/pkg/cellular/modem/sim_test.zig` | 新建 | SIM 管理单元测试 |
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
cd test/unit && zig build test
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
| `src/pkg/cellular/modem/signal.zig` | 新建 | 信号质量查询 |
| `test/unit/pkg/cellular/modem/signal_test.zig` | 新建 | 信号查询单元测试 |
| `test/firmware/110-cellular/app.zig` | 修改 | 追加信号查询验证逻辑 |

**实现内容：**
- `Signal` 结构体：
  - `init(at_engine: *AtEngine) Signal`
  - `getStrength() !CellularSignalInfo` — 发送 AT+CSQ（及 AT+QCSQ）并解析
  - `getRegistration() !CellularRegStatus` — 发送 AT+CGREG? / AT+CEREG? 并解析
  - `getNetworkType() !RAT` — 发送 AT+QNWINFO 并解析

**Mock 测试命令：**

```bash
cd test/unit && zig build test
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

### Step 7: cellular.zig reducer — 状态机纯逻辑

**目标：** 实现 Cellular 的 reduce 函数（纯状态转换逻辑）。

**验证方式：Mock 验证 + 可选烧录验证**

**理由：** reducer 是纯函数：输入 (ModemState, ModemEvent) → 输出新 ModemState。
没有任何 IO 操作，Mock 即可完整覆盖。
但建议在真机上跑一遍状态转换序列，验证嵌入式环境下的内存布局、
对齐、tagged union dispatch 等行为与开发机一致。

**注意：** R25 后 reducer 属于 Cellular 层，不在 Modem 中。Modem 是纯硬件驱动，不持有状态机。

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/pkg/cellular/cellular.zig` | 新建（部分） | 先只实现 reduce 函数 |
| `test/unit/pkg/cellular/cellular_test.zig` | 新建 | Cellular reducer 单元测试 |

> 注：cellular.zig 和 cellular_test.zig 放在 `pkg/cellular/` 根目录，不在子目录中。

**实现内容：**
- `reduce(state: *ModemState, event: ModemEvent) void` — 纯状态转换函数
- 状态转换规则详见 plan.md 第 6 节 Reducer

**测试命令：**

```bash
cd test/unit && zig build test
```

**测试用例：** 见 §8.9；运行 `zig build test-cellular`。

**通过标准：** cellular 相关测试全部通过。

**可选烧录验证（手动 dispatch `ModemEvent`）：**

```
reduce(&s, .power_on)                    → probing
reduce(&s, .bootstrap_probe_ok)          → at_configuring
reduce(&s, .bootstrap_echo_ok)
reduce(&s, .bootstrap_cmee_ok)          → checking_sim
reduce(&s, .{ .sim_status_reported = .ready }) → registering
reduce(&s, .{ .network_registration = .registered_home }) → registered
reduce(&s, .dial_requested)             → dialing
reduce(&s, .dial_succeeded)            → connected
reduce(&s, .ip_lost)                  → registered
reduce(&s, .{ .signal_updated = .{ .rssi = -73 } })  → signal 更新
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
| `src/pkg/cellular/modem/modem.zig` | 新建 | init / at() / pppIo() 路由逻辑 |
| `src/pkg/cellular/modem/profiles/quectel_stub.zig` | 新建 | 占位 Module（仅 Step 8 用；Step 12 由完整 quectel.zig 替代） |
| `test/unit/pkg/cellular/modem/modem_test.zig` | 新建 | Modem 路由单元测试 |
| `test/firmware/110-cellular/app.zig` | 修改 | 追加 Modem 路由验证逻辑 |

**实现内容：**
- **Step 8 最小可运行约定**：此步使用 **占位 Module**（如 `profiles/quectel_stub.zig`：仅含 Probe 等最少命令、满足 §5.7 Module 契约，init_sequence 可为空或仅 Probe）与 **gpio=null**。完整 Module（profiles/quectel.zig / profiles/simcom.zig 的 commands、urcs、init_sequence）在 **Step 12** 实现；Step 8 不实现完整模组适配，只验证 Modem 路由与 at()/pppIo() 透传。
- `InitConfig` 结构体（io / at_io / data_io / config）
- `Modem.init(cfg: InitConfig) Modem` — 根据参数自动选择 single/multi 模式
- `Modem.deinit()`
- `Modem.at() *AtEngine` — 返回 AT 引擎引用
- `Modem.pppIo() ?Io` — 返回 PPP 数据通道
- 模式判断逻辑：data_io != null → multi-channel，否则 single-channel
- **注意：** Modem 不再有 dispatch/getState/isDirty/commitFrame，状态机在 Cellular 层

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
1. 用占位 Module（profiles/quectel_stub）与 gpio=null 实例化 Modem，Modem.init(.{ .io = uart_io, .time = ..., .gpio = null }) 创建 Modem（single-channel 模式）
2. 通过 modem.at() 获取 AtEngine
3. 发送 AT 指令验证路由正确性：

   [I] === Step 8: Modem routing test ===
   [I] Modem mode: single_channel
   [I] modem.at().send("AT") -> status=ok
   [I] modem.at().send("ATI") -> Quectel EC25 ...
   [I] modem.pppIo() = null (CMUX not active yet, expected)
```

**通过标准：**
- Modem.init() 成功，mode = single_channel
- modem.at().send("AT") 返回 ok（证明路由到了正确的 Io）
- modem.pppIo() 返回 null（CMUX 未激活，符合预期）

---

### Step 9: cmux.zig — CMUX 帧编解码（核心里程碑 #2）

**目标：** 实现 GSM 07.10 CMUX 协议，在真机上完成 CMUX 协商和虚拟通道通信。

**验证方式：烧录验证**

**理由：** CMUX 协议的正确性高度依赖真实模组的实现。不同模组对 CMUX 的支持
细节可能不同（帧长度、FCS 计算、SABM/UA 时序等）。必须真机验证。

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/pkg/cellular/at/cmux.zig` | 新建 | CMUX 帧编解码 + 虚拟通道复用 |
| `test/unit/pkg/cellular/at/cmux_test.zig` | 新建 | CMUX 单元测试 |
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
cd test/unit && zig build test
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

### Step 10: modem.zig 完整 — Modem CMUX 全链路（里程碑 #3）

**目标：** 补全 Modem 的 CMUX 管理逻辑，在真机上验证完整的单通道模式全链路。

**验证方式：烧录验证**

**理由：** 这是 Modem 硬件驱动层的集成验证。Modem 在单通道模式下自动管理 CMUX，
通过 modem.at() 和 modem.pppIo() 对外暴露独立的 AT 和 PPP 通道。
必须在真机上验证完整流程。

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/pkg/cellular/modem/modem.zig` | 修改 | 补全 enterCmux/exitCmux |
| `test/firmware/110-cellular/app.zig` | 修改 | Modem 全链路验证逻辑 |

**补全的实现内容：**
- `Modem.enterCmux() !void` — 单通道：AT+CMUX=0 + SABM/UA + Io 切换
- `Modem.exitCmux() void` — 单通道：DISC + 恢复原始 Io
- `Modem.isCmuxActive() bool`
- `Modem.enterDataMode() !void` — ATD*99# → CONNECT
- `Modem.exitDataMode() void` — +++ / ATH

**补全的 Mock 测试用例（之前跳过的 4 个）：**

| ID | 测试名 | 验证内容 |
|----|--------|----------|
| MD-08 | single-ch enterCmux | AT+CMUX=0 发出，SABM/UA，Io 切换 |
| MD-09 | single-ch CMUX AT | CMUX 后 at().send → CMUX DLCI 2 |
| MD-10 | single-ch CMUX PPP | CMUX 后 pppIo() → CMUX DLCI 1 |
| MD-11 | single-ch exitCmux | DISC 发出，AT 恢复到 raw Io |

**烧录验证逻辑（Modem 驱动层全链路）：**

```
[I] ========================================
[I] Step 10: Modem driver integration test
[I] ========================================

Phase 1: 初始化
   var modem = Modem.init(.{ .io = uart_io, .time = board.time });
   [I] Modem initialized: mode=single_channel

Phase 2: 直连 AT（CMUX 前）
   const r1 = modem.at().send("AT", 5000);
   [I] Direct AT -> status=ok

Phase 3: SIM + 信号查询（通过 Modem.at()）
   var sim = Sim.init(modem.at());
   [I] SIM: ready
   var sig = Signal.init(modem.at());
   [I] Signal: rssi=-73, reg=registered_home

Phase 4: 进入 CMUX
   modem.enterCmux();
   [I] CMUX negotiated, channels open
   [I] modem.isCmuxActive() = true

Phase 5: 通过 CMUX AT 通道验证
   const r2 = modem.at().send("AT+CSQ", 5000);
   [I] CMUX AT channel -> +CSQ: 20,0

Phase 6: PPP 通道就绪
   const ppp = modem.pppIo();
   [I] PPP Io available: true

Phase 7: 退出 CMUX
   modem.exitCmux();
   [I] CMUX closed, modem.isCmuxActive() = false

Phase 8: 恢复直连 AT
   const r3 = modem.at().send("AT", 5000);
   [I] Post-CMUX direct AT -> status=ok

[I] ========================================
[I] MODEM DRIVER TEST PASSED
[I] ========================================
```

**通过标准：**
- 8 个 Phase 全部成功执行，无崩溃
- 直连 AT → CMUX AT → 退出 CMUX → 直连 AT 全链路通畅
- PPP Io 在 CMUX 激活后可用
- 串口 log 最终输出 "MODEM DRIVER TEST PASSED"

**这是第三个里程碑：Modem 硬件驱动在 ESP32S3 + 真实 4G 模组上全链路跑通。**

---

### Step 11: cellular.zig — 事件源 + Injector + Control 集成（最终里程碑）

**目标：** 实现 Cellular 事件源层与 **CellularControl**（Phase 1，参考 BLE Host）。在 Step 7 的 reducer 基础上补全：worker 线程、Injector 事件推送、**请求队列 + response channel + Control handle**、与 Modem 的集成。在真机上验证 Cellular 能自动驱动 Modem、推事件入 Bus，且用户可通过 control.getSignalQuality(timeout_ms) 等按需查询；**用户请求的 timeout 不喂给 reducer**（6.1.1）。

**验证方式：烧录验证 + Mock 验证**

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/pkg/cellular/types.zig` | 修改 | 新增 ControlRequestTag、ControlRequest、ControlResponse（见 5.8.1） |
| `src/pkg/cellular/cellular.zig` | 修改 | 补全 init/start/stop/tick/emitIfChanged；**新增** request_queue、response_channel、CellularControl 类型与 control() 方法；worker 在 tick 后处理 Control 请求并只写 response，不送 reducer |
| `test/unit/pkg/cellular/cellular_test.zig` | 修改 | 追加 CE-01～CE-07 与 **CT-01～CT-03**（Control 与生命周期隔离） |
| `test/firmware/110-cellular/app.zig` | 修改 | 使用 AppRuntime + Bus；可选：调用 cell.control().getSignalQuality(5000) 验证按需查询 |

**实现内容（在 Step 7 基础上追加）：**

- **事件源（与现有一致）**  
  - `Cellular.init(allocator, modem_cfg, injector, config)` — 创建 Modem、injector、**request_queue、response_channel**、初始 state；不创建 Channel 用于事件。  
  - `Cellular.start()` / `stop()` — 启动/停止 worker。  
  - `Cellular.tick()` — 生命周期：pumpUrcs → 查询 Modem → reduce → emitIfChanged；**仅**此路径的 AT 结果可推断 ModemEvent 并送入 reduce。  
  - `Cellular.emitIfChanged()` — 状态变化时 `injector.invoke(payload)`。

- **Control（5.8.1 可操作规格）**  
  - `Cellular.control()` — 返回 `*CellularControl`，持有 request_queue 的 send 端与 response_channel 的 recv 端（或等价句柄）。  
  - `CellularControl.getSignalQuality(timeout_ms)` — 若 phase 不可用则返回 `error.Uninitialized`；否则 send(.get_signal_quality)，再 `response_channel.timedRecv(timeout_ms)`；若超时则向**调用方**返回 `error.Timeout`，**不**调用 reduce、不增加 at_timeout_count。  
  - `CellularControl.send(comptime Cmd, cmd, timeout_ms)` — 同上，入队 .send_at，timedRecv 等结果；超时/AT 错误仅作为该次调用的错误。  
  - Worker 循环：在每次 tick() 之后，`request_queue.tryRecv()`；若有请求则执行（getStrength 或 at().send），将结果写入 response_channel（.signal_quality / .at_ok / .at_error / .timeout / .uninitialized）；**绝不**把此次执行产生的超时或错误送入 reduce。

**Mock 测试用例（7 个 CE + 3 个 CT，追加到 cellular_test.zig）：**

| ID | 测试名 | 验证内容 |
|----|--------|----------|
| CE-01 | phase change emits event | tick() 检测到 phase 变化 → 测试 injector 被调用，收到 phase_changed payload |
| CE-02 | signal update emits event | 信号变化 → injector.invoke(signal_updated) |
| CE-03 | sim status change emits event | SIM 拔出 → injector.invoke(sim_status_changed) |
| CE-04 | no change no event | tick() 状态不变 → 无 invoke |
| CE-05 | start/stop lifecycle | start() 启动线程，stop() 正常 join |
| CE-06 | injector integration | tick() 后从测试 injector 绑定的 channel 或 Bus.recv() 能收到 CellularPayload |
| CE-07 | error emits event | AT 超时达到阈值 → injector.invoke(error) |
| **CT-01** | **lifecycle at_timeout → error** | **仅**生命周期路径：连续 3 次 at_timeout → at_timeout_count 增至 3 → phase=error、error_reason=at_timeout；reducer 行为与 6.1 一致 |
| **CT-02** | **control timeout 不干扰 reducer** | Control.getSignalQuality(timeout_ms) 多次超时（或 worker 回 .timeout）；**断言** state.phase 不变、at_timeout_count 不增加、无 injector.invoke(error) 被误触发 |
| **CT-03** | **control 按需查询** | phase == .ready 时 control.getSignalQuality(5000) 返回有效 CellularSignalInfo；phase == .off 时返回 error.Uninitialized；可选：control.send(GetCsq, .{}, 5000) 返回 OK |

**烧录验证逻辑（追加到 app.zig）：**

固件内需有 App + Bus + AppRuntime。InputSpec 包含 `.cellular = CellularPayload`。创建 Cellular 时传入 `rt.bus.Injector(.cellular)`。主循环使用 `rt.recv()` 收事件、`rt.dispatch()` 更新 state，再根据 state 或事件内容打印 log。

```
[I] ========================================
[I] Step 11: Cellular event source test
[I] ========================================

Phase 1: 创建 Cellular（传入 rt.bus.Injector(.cellular)）
   const injector = rt.bus.Injector(.cellular);
   var cell = Cellular.init(allocator, .{ .io = uart_io, .time = board.time }, injector, .{});
   [I] Cellular initialized

Phase 2: 启动 worker
   cell.start();
   [I] Cellular worker started

Phase 3: 主循环收事件（rt.recv() → rt.dispatch()）
   -- 5 秒内应通过 rt.recv() 收到 .input.cellular 的 phase_changed 等
   const r = rt.recv();
   if (r.value == .input and r.value.input == .cellular) {
       switch (r.value.input.cellular) {
           .phase_changed => |p| log("phase_changed { } -> { }", .{ p.from, p.to }),
           ...
       }
   }
   rt.dispatch(r.value);
   [I] Event received: phase_changed .off -> .probing
   [I] Event received: phase_changed .probing -> .at_configuring
   …（直至 .registered 等，见 R44）

Phase 4: 持续收事件（10 秒内观察 signal_updated、phase_changed 等）
   [I] Event: signal_updated rssi=-73
   [I] Event: phase_changed …（按实际 bootstrap 阶段）

Phase 5: Control 按需查询（可选）
   const ctrl = cell.control();
   const sig = ctrl.getSignalQuality(5000) catch |e| { log("control err: {}", .{e}); return };
   [I] Control.getSignalQuality() -> rssi=-73

Phase 6: 停止
   cell.stop();
   [I] Cellular worker stopped

[I] ========================================
[I] CELLULAR EVENT SOURCE TEST PASSED
[I] ========================================
```

**通过标准：**
- Cellular 自动驱动 Modem 完成初始化序列
- 通过 rt.recv() 能收到 .input.cellular 的 phase_changed / signal_updated / sim_status_changed 等
- **Control**：phase 就绪时 control.getSignalQuality(timeout_ms) 能返回有效信号；phase == off 时返回 Uninitialized；用户请求超时仅该次调用失败，不触发 phase=error
- Worker 线程正常启动和停止，无死锁
- 串口 log 最终输出 "CELLULAR EVENT SOURCE TEST PASSED"

**这是最终里程碑：Cellular 事件源 + Control 在真机上自动驱动 Modem、推事件入 Bus，且用户可安全按需查询。**

---

### Step 12: modem/profiles/quectel.zig & modem/profiles/simcom.zig — 模块适配层 (R31)

**目标：** 为 Quectel 和 SIMCom 模块创建命名空间文件，导出各自专属的 commands、URCs 和 init sequence。

**验证方式：Mock 验证**

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/pkg/cellular/modem/profiles/quectel.zig` | 新建 | Quectel 模块适配（commands, urcs, init_sequence） |
| `src/pkg/cellular/modem/profiles/simcom.zig` | 新建 | SIMCom 模块适配（commands, urcs, init_sequence） |
| `test/unit/pkg/cellular/modem/profiles/quectel_test.zig` | 新建 | Quectel 专属命令/URC 测试 |
| `test/unit/pkg/cellular/modem/profiles/simcom_test.zig` | 新建 | SIMCom 专属命令/URC 测试 |

**验证命令：**

```bash
cd test/unit && zig build test
```

**通过标准：** 8 个新测试通过（QC-01~04, SC-01~04），Modem(comptime Module) 能正确消费两种 Module 的 namespace。

---

### Step 13: mod.zig 导出 + 收尾

**目标：** 将 cellular 包注册到项目模块树，确保编译和测试都能通过。

**验证方式：Mock 验证（编译检查）**

**涉及文件：**

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/mod.zig` | 修改 | 在 pkg 下添加 cellular 导出 |
| `test/unit/mod.zig` | 修改 | 添加 cellular 测试导入 |

**验证命令：**

```bash
zig build                          # 根目录库编译检查（含 refAllDecls）
cd test/unit && zig build test     # 运行全部单元测试（含 cellular）
```

**通过标准：** 所有 121 个测试通过，无编译错误。

---

### 总览表

| Step | 文件 | 验证方式 | Mock 测试数 | 烧录验证重点 | 里程碑 |
|------|------|----------|------------|-------------|--------|
| 0 | 基础设施 | **烧录** | 0 | UART 原始字节收发 | |
| 1 | types.zig | Mock | 3 | — | |
| 2 | io.zig | **烧录** | 3 | Io 透传 UART 到模组 | |
| 3 | parse.zig | Mock + **可选烧录** | 11 | 用真实模组响应验证解析兼容性 | |
| 4 | engine.zig + commands.zig | **烧录** | 19 | AT 引擎端到端 + 命令类型校验 | **里程碑 #1** |
| 5 | sim.zig | **烧录** | 7 | 真实 SIM 信息读取 | |
| 6 | signal.zig | **烧录** | 7 | 真实信号查询 | |
| 7 | cellular reducer | Mock + **可选烧录** | 21 | 验证嵌入式环境下内存布局和状态转换 | |
| 8 | modem 路由 | **烧录** | 13 | Modem 抽象层 AT 透传 | |
| 9 | cmux.zig | **烧录** | 10 | CMUX 真机协商 | **里程碑 #2** |
| 10 | modem 完整 | **烧录** | 4 | Modem CMUX 全链路 | **里程碑 #3** |
| 11 | cellular.zig | **烧录** | 10 | Cellular 事件源 + Injector + Control | **最终里程碑** |
| 12 | quectel/simcom | Mock | 8 | — | |
| 13 | mod.zig 导出 | Mock | 0 | — | |

**总计：121 个 Mock 测试 + 8 次必须烧录验证 + 2 次可选烧录验证**（含 Step 11 的 3 个 Control 测试 CT-01～CT-03）

### Phase 2（可选，后续扩展）

> 注：Step 0~13 为 Phase 1。Phase 2 在 Phase 1 全部完成并验证后再开始。

| 文件 | 说明 |
|------|------|
| voice.zig | 语音通话管理（dial/answer/hangup） |
| apn.zig | APN 自动解析（根据 IMSI 匹配运营商） |

**注：** Control handle（CellularControl）已在 **Phase 1 Step 11** 实现，参考 BLE Host；用户请求 timeout 不喂 reducer，见 5.8.1、6.1.1、R37。

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

### R22 (2026-03-12)

**Topic:** Q7 电源管理 + Q8 close/flush + Q9 CMUX 职责

**Q7 — 电源管理接口：**
1. 审查了 C 代码 `quectel_task.c` 的电源控制实现：使用 `enable_modem`/`disable_modem` 可选回调
2. 发现现有硬件使用 auto-start 模式（GPIO 使能供电，模组自动启动），不需要 PWRKEY 脉冲
3. 错误恢复（ERROR state）不做硬件复位，只重走状态机
4. 调研了各厂家（Quectel/SIMCom/u-blox/Fibocom）的开机方式，均为 PWRKEY 脉冲但时长不同，且都支持 auto-start
5. 决定：PowerControl 作为可选回调放在 InitConfig 中（enable/disable/reset 三个函数指针，均可为 null）→ **R38 修正：改为 `comptime Gpio` 注入**
6. pkg/cellular 只定义接口不实现，各平台根据硬件提供具体 GPIO 操作

**Q8 — close/flush：**
1. close：Io 不负责资源释放，调用方管理生命周期（与 C 代码一致）
2. flush：所有模式切换都有 AT command-response 天然同步点，不需要显式 flush
3. Io 保持 read/write/poll 三个操作

**Q9 — CMUX open() 职责：**
1. AT+CMUX=0 是 AT 层的事（AtEngine 发送），SABM/UA 是 CMUX 帧层的事（Cmux.open() 处理）
2. Modem.enterCmux() 是编排者：AtEngine.send("AT+CMUX=0") → Cmux.open() → startPump → setIo
3. Cmux.open() 的 doc comment 需明确标注"caller must send AT+CMUX=0 before calling"
4. 详细的 enterCmux/exitCmux 五步流程写入实施规格

### R23 (2026-03-12)

**Topic:** Q10 — PPP/lwIP 集成分析 + 暂缓决定

1. 分析了 C 代码的 PPP 实现：完全依赖 ESP-IDF `esp_modem`，`quectel_cmux_enter_ppp()` → `esp_modem_set_mode(CMUX_MANUAL_DATA)` 一行搞定 ATD*99# 到 PPP 协商全流程
2. 审查了现有 Zig 代码的 WiFi/网络分层：
   - `hal/wifi.zig`：纯硬件驱动，不涉及 IP/lwIP
   - `runtime/netif.zig`：通用网络接口查询（只读），不负责创建网卡
   - `runtime/std/netif.zig`：只提供 loopback 接口
   - 结论：**WiFi 也没有 lwIP 集成**，IP 层由平台胶水（ESP-IDF esp_netif）处理
3. 确认 cellular 应对齐 WiFi 的模式：pkg/cellular 提供到 pppIo()，PPP/lwIP 由外部处理
4. 用户通知：main 分支即将进行重大 IO 重构：
   - 统一 uart/ble/hci/wifi/modem 的 IO + poll 机制
   - 新增 `pkg/lwip` — lwIP 的 Zig 绑定，用户态网络栈
   - 新增 netlink 抽象 — WiFi 和 modem 作为数据链路层
5. 重构将改变：Io 接口定义、PPP/lwIP 集成方式、数据流架构
6. 决定：Q10 暂缓，等 main 重构完成后再对齐。当前可先推进 AT 引擎、CMUX、状态机、PowerControl 等不受影响的部分

### R21 (2026-03-12)

**Topic:** Q6 — Io poll/超时语义完整解决 + 风格对齐

1. 分析了 poll 的本质：高效等待数据就绪，避免忙等（对比 POSIX select/poll/epoll 三代演进）
2. 确认 Io 可以用 type-erased 方式统一暴露 poll 能力，各平台提供最高效实现
3. 分析了 CMUX 下的两层 timeout：物理层 poll timeout（pump 节拍 ~10ms）vs 业务层 AT 命令 timeout（~5000ms）
4. 确认 CMUX 虚拟通道不需要物理层 poll，但 USB 直连模式必须有 pollFn
5. 分解为 4 个子问题按依赖顺序推导：Q6-d → Q6-c → Q6-a → Q6-b
6. Q6-d：pump 由独立线程驱动（利用已有 runtime/thread.zig + runtime/sync.zig）
7. Q6-c：CMUX 虚拟通道的 pollFn 用 Notify.timedWait 包装 → AtEngine 统一用 poll+read 循环
8. 关键修正：pollFn 从"可选"改为"必须"，因为 Notify 包装使得所有 Io 都能提供 poll 语义
9. Q6-a：read() 约定非阻塞（WouldBlock），与 HAL uart.zig 行为一致
10. Q6-b：Time 通过 comptime 类型参数注入（非裸函数指针），各平台提供毫秒时间源
11. 风格对齐：审查现有 pkg 模块（button/timer/motion/audio/ble），发现平台依赖统一用
    comptime 类型参数注入（Thread/Time/Notify/Mutex）。将 cellular 的 AtEngine/Cmux/Modem
    对齐到此模式。Io 保持 type-erased（运行时 CMUX 切换的合理例外）
12. 更新了 io.zig（加 PollFlags + pollFn）、at.zig（comptime Time）、
    cmux.zig（comptime Thread + Notify）、modem.zig（comptime Thread + Notify + Time）接口规格

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
   - MockIo 使用两段线性 buffer（tx_buf/tx_len、rx_buf/rx_len/rx_pos），与 pkg/net 的 MockConn 风格一致
   - Removed UART-specific assumptions

8. Test plan updated:
   - MockIo replaces MockUart as universal test transport
   - Added multi-channel mode tests (MD-02, MD-05, MD-06, MD-07, MD-12)
   - Added init validation test (MD-03)
   - Total: 83 tests (was 78)

9. Usage examples added for ESP32/Linux/Test scenarios

### R33 (2026-03-16)

**Topic:** Q25 解决 — enterCmux 环节与失败处理（参考 quectel C 代码）

参考 `x/c/esp/components/quectel`：

**enterCmux 在哪个环节进入？**
- 状态机顺序：INIT → MODEM_POWERING → WAIT_SIM → **CMUX_INIT** → NETWORK_REG → PPP_DIAL → ONLINE …
- 进入 CMUX_INIT 的条件：**WAIT_SIM 阶段 SIM 已 ready**（wait_sim_ready 返回 0）后，才 set_state(CMUX_INIT)。即 **sim_ready 之后** 才调 init_cmux（等价 enterCmux）。
- 例外：warm boot 且之前 SIM 已插入时，可从 MODEM_POWERING 直接跳到 CMUX_INIT（跳过 WAIT_SIM）。

**失败之后怎么处理？**
- Task 层（quectel_task.c 709–717）：CMUX_INIT 状态下若 init_cmux(task) != 0，**直接 set_state(ERROR)**，无重试、无回退到 WAIT_SIM。
- CMUX 层（quectel_cmux.c）内部：AT+IPR 失败则 goto normal_cmux_init 用当前波特率再试；UART 设波特率失败则返回错误并设 state=ERROR；新波特率下 AT 验证 5 次仍失败则恢复 UART 到 base_baud 再 goto normal_cmux_init；esp_modem_set_mode(CMUX_MANUAL) 失败则尝试恢复 UART 波特率并返回 QUECTEL_ERR_CMUX_FAILED，state=ERROR。
- 结论：**失败即进 ERROR，由应用/用户决定是否重试**（与 plan 中 retry 事件一致）；C 代码 task 内部不做 CMUX 自动重试。

**Zig 对齐（R44）：** 在 **`sim_status_reported(.ready)` 之后**（phase 至少为 `registering`）再调 `enterCmux`。失败 → `error`；`retry` → `probing`。

### R34 (2026-03-16)

**Topic:** commands.zig 按 3GPP 标准分类注释

1. 调研了 ublox-cellular-rs 的 `src/command/` 目录，发现它按 u-blox AT 手册分了 18 个子模块
2. 但并非穷举所有 AT 命令，SMS 模块只有 1 条 UMWI，没有 CMGS/CMGR 等核心命令
3. 确认策略：按需定义，不穷举。但在 commands.zig 中按功能分类列出所有标准类别
4. 分为 13 类：
   - 1. General (V.25ter / 27.007 Ch4): AT, +CGMI, +CGMM, +CGMR, +CGSN
   - 2. Control (V.25ter / 27.007 Ch5): ATE, +CMEE, +IPR, ATZ
   - 3. SIM / Device Lock (27.007 Ch8-9): +CPIN, +CIMI, +CCID, +CLCK
   - 4. Mobile Control (27.007 Ch6): +CFUN, +COPS
   - 5. Network Service (27.007 Ch7): +CREG, +CGREG, +CEREG, +CSQ
   - 6. PDP / Packet Domain (27.007 Ch10): +CGDCONT, +CGATT, +CGACT
   - 7. Call Control (V.25ter): ATD, ATH, ATA
   - 8. SMS (27.005): +CMGF, +CMGS, +CMGR, +CMGL, +CNMI
   - 9. CMUX (27.010): +CMUX
   - 10. TCP/IP (vendor-specific): u-blox +USO*, Quectel +QI*, SIMCom +CIP*
   - 11. HTTP/MQTT/FTP (vendor-specific)
   - 12. GNSS/GPS (vendor-specific)
   - 13. Power/Sleep (vendor-specific): +CPSMS, +CEDRXS
5. 核心状态机流程用到的命令（1-7, 9 类中的关键命令）给出完整 struct 实现
6. 其余类别只留注释标注关键命令名，由 module profile 或专用文件按需实现
7. 新增了 Probe, GetManufacturer, GetModel, GetFirmwareVersion, GetImei, SetEcho,
   SetErrorFormat, SetFunctionality, GetIccid, SetApn, GetAttachStatus,
   SetRegistrationUrc, Hangup, SetCmux 等命令 struct

### R42 (2026-03-16)

**Topic:** tick() 按 phase 单条 AT + Q15 修正移除 onSend()

1. 对比业界主流 cellular 驱动的状态机 tick 模式：
   - **quectel C**：`switch(task->state)`，每个状态只做该阶段的事。MODEM_POWERING 发 AT probe + init 序列，WAIT_SIM 等事件，NETWORK_REG 发 AT+CGREG?/CEREG?，ONLINE 不轮询。不会在一次 tick 里同时查 SIM + 信号 + 注册
   - **ublox-cellular-rs**：async Runner 按阶段推进，每次只推进一步。信号/注册靠 URC 被动接收
   - **Zephyr modem**：`setup_cmds` 逐条发送，每条之间有 delay。GitHub #47082 明确指出上一条 OK 没收完就发下一条会出 bug
2. 原 plan 的 tick() 每次无条件发 3 条 AT（AT+CPIN? + AT+CSQ + AT+CREG?）的问题：
   - off/starting 阶段查信号无意义
   - dialing/connected 阶段频繁 AT 可能干扰数据通道
   - 不符合业界惯例
   - 注册/SIM 状态变化有 URC，不需要主动轮询
3. 改为 `switch(phase)`，每个阶段最多一条 AT（R44）：
   - off → 无；probing → AT；at_configuring → ATE0/CMEE；checking_sim → CPIN；registering → CEREG
   - registered / dialing / connected → 由 URC 或应用事件推进；registering 内由 CEREG 结果推进；error → 等 retry
4. Q15 修正：MockIo 移除 `onSend()` 自动应答，与 BLE `MockHci` 对齐只保留 FIFO `feed()`
   - 每次 tick 只发一条 AT，测试只需按顺序 feed 一条响应
   - 复杂流程用 `feedSequence()` 一次性预填（类比 BLE `injectInitSequence()`）
   - 测试代码更简单直观，无需理解匹配规则

### R40 (2026-03-16)

**Topic:** Q12 解决 — AtResponse 缓冲区从按行分割改为单一平坦缓冲区

1. 对比了 esp_modem (C++) 和 atat/ublox-cellular-rs (Rust) 的缓冲区策略：
   - **esp_modem**：`dte_buffer_size` 默认 512 字节，单一平坦缓冲区。回调收到整块数据自行分行。C API 返回字符串截断上限 `ESP_MODEM_C_API_STR_MAX` 默认 128（Kconfig 可改）。v1.2+ 引入 `INFLATABLE_BUFFER` 动态扩容。已知痛点：GitHub 多个 issue 报告长响应截断（#624, #783, #406）
   - **atat**：`const generic` 编译期配置。`SimpleClient` 接收调用方传入的 `&mut [u8]` 切片。`Client` + `Ingress` 用 `RES_BUF_SIZE` const generic 控制 `ResponseSlot<N>`（`heapless::Vec<u8, N>`）。零堆分配，溢出返回 `Error::Parse`
2. 原 plan 的 `[8][128]u8` 有两个问题：ATI 可能超 8 行，AT+COPS=? 单行可能超 128 字节
3. 采用 atat 方案：单一平坦缓冲区 `[buf_size]u8`，大小由 `comptime buf_size` 控制
4. AtResponse 改为内嵌于 AtEngine 的类型，body 为指向 rx_buf 的切片（不含最终 OK/ERROR），通过 `lineIterator()` 按需遍历行
5. 新增 `AtStatus.overflow` 状态，缓冲区满时返回明确错误而非截断
6. AtEngine 签名从 `AtEngine(comptime Time)` 变为 `AtEngine(comptime Time, comptime buf_size)`
7. Modem/Cellular 签名透传 `at_buf_size` 参数
8. 更新了所有使用示例（7.1~7.4）和 Q6 实施规格

### R38 (2026-03-16)

**Topic:** PowerControl 修正 — 从函数指针改为 `comptime Gpio` 注入 + 剩余配置项分析

1. 检查了 `hal/gpio.zig`、`hal/uart.zig`、`hal/marker.zig` 和 `pkg/event/button/gpio/button.zig`
2. 发现项目已有完整的 HAL trait 抽象：`from(comptime spec)` 做编译期签名校验，`is()` 做类型判定
3. 之前 R22 的结论"Zig 没有 HAL trait 抽象，用函数指针更务实"**完全错误**
4. PowerControl 应对齐现有 HAL 模式：Modem 签名加 `comptime Gpio: type`，编译期校验 `hal.gpio.is(Gpio)`
5. 旧 `PowerControl` struct（3 个函数指针）替换为 `PowerPins` struct（3 个可选 `?u8` pin 编号）
6. 通过注入的 `Gpio` 实例调用 `setLevel`/`getLevel`，与 `Button` 注入 GPIO 的方式一致
7. 新增 `vint_pin`（电源状态反馈引脚），通过 `getLevel` 读取，`isPowered()` 返回 `?bool`
8. 剩余 4 个配置项逐项分析：
   - **set_rate**（波特率切换）：**保持运行时回调**。`hal/uart` 合约无 `setBaudRate`，加进去会破坏现有合约；仅 CMUX 初始化用一次，不值得扩展 HAL；USB/SPI 不需要
   - **CONTEXT_ID**：**加入 ModemConfig 作为 `context_id: u8 = 1`**。简单常量，不需要 comptime 泛型；不同 SIM/运营商可能需要不同值，运行时可配更灵活
   - **VintPin**：**合并到 `comptime Gpio` 方案中**，作为 `PowerPins.vint_pin: ?u8`
   - **apn_lookup**：**保持 phase 2**，作为 `Module` 命名空间的可选导出（`@hasDecl(Module, "apn_lookup")`）
9. 更新了 5.7 modem.zig 的 Modem 签名、Q7 实施规格、平台示例

### R35 (2026-03-16)

**Topic:** 错误与重试融入状态机（统一 Error 类型 + 重试/超时由状态机驱动）

1. 对比 C (quectel) 与 Rust (ublox-cellular-rs)：C 在波特率探测、配置失败、SIM 状态、AT 通道健康、PPP 失败、错误恢复等方面更务实（软恢复、忽略可忽略失败、连续 N 次才进 ERROR）。
2. 原则：重试与超时在状态机内部通过计数/阈值处理；**只有达到重试次数或超时后**才进 error 并向 Flux 抛 `CellularEvent.error(ModemError)`。
3. 统一错误类型 `ModemError`（types.zig）；ModemState 增加 `error_reason`、`at_timeout_count`。
4. Reducer（R44）：具名 `ModemEvent`；error + retry → probing。tick 只 dispatch 事件，由 reducer 改 phase。
5. 详见 Section 6.1。

### R31 (2026-03-16)

**Topic:** ResponseMatcher + ModuleProfile 简化

1. 讨论了 `ResponseMatcher` 和 `ModuleProfile` 两个概念是否需要独立类型
2. **ResponseMatcher 简化**：不引入独立的 `ResponseMatcher` 接口，而是将其合并为 Command struct 的可选 `match` 方法
   - 大多数 AT 命令使用标准 OK/ERROR 终止，不需要自定义 matcher
   - 少数命令（如 `ATD` 拨号等待 `CONNECT`、多行响应命令）需要非标准终止检测
   - Command struct 可选提供 `match(line: []const u8) MatchResult` 方法
   - `AtEngine.send` 在 comptime 通过 `@hasDecl(Cmd, "match")` 检测，有则使用 `sendRawWithMatcher`，无则走默认 `sendRaw`
   - 一个 Command struct = 发什么 + 怎么判断收完 + 怎么解析结果，三位一体
3. **ModuleProfile 简化**：不引入独立的 `ModuleProfile` comptime 接口，而是用命名空间文件替代
   - `modem/profiles/quectel.zig` 导出 Quectel 专属的 commands、URCs、init sequence
   - `modem/profiles/simcom.zig` 导出 SIMCom 专属的 commands、URCs、init sequence
   - 通用命令（`AT+CSQ`、`AT+CPIN?` 等）仍在 `at/commands.zig`
   - 模块专属命令（如 Quectel 的 `AT+QCFG`、SIMCom 的 `AT+CSCLK`）在各自文件中定义
   - `Modem` 层通过 `comptime Module: type` 泛型参数选择模块，`Module` 只需导出约定的 namespace（commands/urcs/init_sequence）
4. 这种方式避免了引入新的抽象层，复用了 R28 的 Command as Type 模式
5. 新增 `modem/profiles/quectel.zig`、`modem/profiles/simcom.zig` 及对应测试文件

### R29 (2026-03-16)

**Topic:** TraceIo Decorator + URC 类型化

1. 调研了 warthog618/modem (Go) 的 `trace` 包：Decorator 模式，插在 `at` 和 `serial` 之间，
   记录所有收发原始字节。不改任何代码，只在构造时插入一层。
2. 调研了 ublox-cellular-rs (Rust) 的 URC 处理：URC 也定义为类型化枚举，每个 variant 有
   对应的解析逻辑，与命令类型系统统一。
3. TraceIo 设计（`io/trace.zig`）：
   - `wrap(inner: Io, log_fn: TraceFn) Io` — 返回新 Io，read/write 时调用 log_fn
   - log_fn 是裸函数指针（runtime Decorator，与 Io type-erased 设计一致）
   - 零侵入：`modem.init(.{ .io = trace.wrap(uart_io, logFn) })`
   - 生产环境不调用 wrap 即零开销
4. URC 类型化设计（`at/urcs.zig`）：
   - 每个 URC 是一个 struct，包含 `prefix` 和 `parseUrc(line) ?Payload`
   - 与 R28 命令类型共享相同的 struct-with-prefix-and-parse 模式
   - AtEngine 新增 `pumpUrcsTyped(comptime Urcs, ctx)` — comptime inline for 遍历所有 URC 类型
   - 预定义 `AllUrcs` tuple 聚合所有已知 URC
5. 新增 9 个测试（4 TraceIo + 5 URC typed），总测试数从 101 增加到 110

### R28 (2026-03-16)

**Topic:** AT 命令类型抽象 — Command as Type, 编译期校验

1. 调研了其他语言（Go/Rust/C）的 4G modem 驱动抽象分层模式：
   - Go (`warthog618/modem`)：`io.ReadWriter` 抽象 + Decorator 模式 + Trace 层
   - Rust (`atat`)：每条 AT 命令是独立 struct，trait `AtatCmd` 定义 Response type + 序列化/解析方法，编译期保证类型安全
   - C (`lwcell`)：OS/LL 分层 + 回调注册
   - C++ (`esp_modem`)：DTE/DCE 分层 + 工厂模式
2. 核心发现：Rust `atat` 的 "Command as Type" 模式可直接映射到 Zig comptime：
   - 每条 AT 命令定义为一个 struct（如 `GetSignalQuality`, `EnterPin`）
   - struct 包含 comptime 常量（`Response` type, `prefix`, `timeout_ms`）和方法（`write`, `parseResponse`）
   - `AtEngine.send(comptime Cmd, cmd)` 在编译期校验命令 struct 的 contract
   - 返回 `SendResult(Cmd)` 其中 `.value` 的类型是 `?Cmd.Response`，编译期确定
3. 对现有 plan 的影响：
   - 新增 `at/commands.zig`：所有 AT 命令类型定义
   - `at/engine.zig` 原 `send()` 改名为 `sendRaw()`（保留低级接口），新增泛型 `send(comptime Cmd, cmd)`
   - `modem/sim.zig` 和 `modem/signal.zig` 简化：从手动拼 AT 字符串 + 手动解析，变为 `engine.send(commands.GetSimStatus, .{})`
4. 好处：
   - 编译期类型安全：拼写错误、类型不匹配 → 编译错误
   - 自文档化：每个命令 struct 就是其规格说明
   - 可独立测试：write/parse 是纯函数
   - 不影响运行时性能：所有 dispatch 在 comptime 完成
5. 新增 8 个测试用例（commands_test.zig），总测试数从 90 增加到 98
6. Section 5 编号顺延（原 5.4 → 5.5，新 5.4 = commands.zig，新 5.5 = engine.zig）

### R30 (2026-03-16)

**Topic:** Q13 解决 — 错误恢复策略简化（方案 2）

1. 其它使用 reducer 的包（flux、app）没有 error_recovery/error_count 模式
2. 采用方案 2：状态机不做自动重试，与现有包对齐
3. 移除 ModemState.error_count
4. ModemEvent.error_recovery 改名为 retry，语义为「应用层请求重试」
5. Reducer：`error` + `retry` → `probing`（R44）
6. 测试用例与描述中去掉对 error_count 的断言

### R27 (2026-03-16)

**Topic:** Q11 解决 — registering 拆分为 registered + dialing

1. 原 `registering` 阶段语义矛盾：收到 `registered` 事件后进入 `registering`
2. 实际上"网络注册"和"PPP 拨号"是两步独立操作，不应合并
3. 拆分为：
   - `registered` — 已注册网络，可以发起 PPP 拨号
   - `dialing` — PPP 拨号进行中（ATD*99# 已发出，等待 CONNECT）
4. 意图事件 `dial_requested`：`registered` → `dialing`（取代旧名 `dial_start`）
5. `dial_failed` 回退到 `registered`（而非 `error`），因为网络仍然注册，可以重试拨号
6. `ip_lost` 也回退到 `registered`（而非原来的 `registering`），语义更准确
7. CellularPhase 枚举从 7 个变为 8 个，reducer 测试从 18 个变为 21 个
8. 总测试数从 98 变为 101

### R26 (2026-03-16)

**Topic:** pkg/cellular 子目录划分

1. 参考 `pkg/ble` 的目录结构（host/hci, host/l2cap, host/gap, gatt, xfer, term）
2. 按层级依赖关系将 cellular 文件分为 4 个区域：
   - `io/` — 传输层（最底层）：io.zig（接口定义 + fromUart/fromSpi）、mock.zig（MockIo）
   - `at/` — AT 协议层（依赖 io）：engine.zig（AT 引擎）、parse.zig（纯解析）、cmux.zig（CMUX 复用）
   - `modem/` — 硬件驱动层（依赖 io + at）：modem.zig（核心路由）、sim.zig（SIM 管理）、signal.zig（信号查询）
   - 根目录 — types.zig（共享类型，所有层都用）、cellular.zig（事件源，最上层）
3. CMUX 放在 at/ 的理由：CMUX 是 AT 通道复用协议，与 AtEngine 同层，类比 BLE 中 L2CAP 和 HCI 都在 host/ 下
4. MockIo 放在 io/ 的理由：是 Io 接口的测试实现，与 Io 定义紧密耦合
5. 测试目录 test/unit/pkg/cellular/ 镜像源码子目录结构
6. 更新了 plan 中所有涉及文件路径的 section（3.4, 4, 5, 8, 9, Q6/Q7/Q8 实施规格）

### R25 (2026-03-16)

**Topic:** Modem/Cellular 拆分 + Channel/Bus 事件集成

1. 分析了 HAL 层现有组件模式（uart/wifi/hci/imu），确认 HAL 是薄包装层：
   - 只做 `is()` + `from(spec)` comptime 验证和方法转发
   - 不持有协议栈、不做帧解析、不管线程
   - 不依赖 runtime（Thread/Channel/Time 等）
2. 对比 Modem 的职责（AT 引擎、CMUX 协议、Io 路由、comptime Thread/Time/Notify），
   确认 Modem 远超 HAL 层的复杂度，与 `pkg/ble/host` 同层
3. 确认 Modem 的 HAL 层已存在：`hal/uart`（read/write/poll），不需要新增 `hal/modem`
4. 将原 Modem 拆分为两层：
   - **Modem**（硬件驱动）：拥有 Io/CMUX/AtEngine，不持有 flux Store 和状态机
   - **Cellular**（事件源）：拥有 Modem + EventInjector(CellularPayload)，在独立线程中驱动状态机，
     将状态变化通过 injector.invoke(payload) 推入 Bus
5. Cellular 对齐现有 peripheral 模式（MotionPeripheral / ButtonPeripheral）：
   - comptime 泛型：Thread, Notify, Time；init 接收 injector（R36 后无 ChannelType）
   - start()/stop() 管理 worker 线程生命周期
   - tick() 内部：pumpUrcs → 查询硬件 → 驱动状态机 → emitIfChanged
6. CellularPayload 通过 injector 推入 Bus 后，主循环 rt.recv()/rt.dispatch() 收集，
   与 button/timer/motion 事件一起进入应用层 reduce
7. 新增 cellular.zig 文件和 cellular_test.zig 测试文件
8. 实施步骤从 11 步扩展为 12 步：
   - Step 7 从 "modem reducer" 改为 "cellular reducer"
   - Step 10 缩小为 "Modem CMUX 全链路"（里程碑 #3）
   - 新增 Step 11 "cellular.zig 事件源 + Injector 集成"（最终里程碑）
   - Step 12 为 mod.zig 导出收尾
9. Mock 测试从 83 个增加到 90 个（+7 cellular 事件发射测试）

### R24 (2026-03-16)

**Topic:** 同步 main 分支更新，对齐测试架构

1. main 分支完成了 5 个提交的更新，at 分支已 rebase 同步
2. main 的主要变更：
   - event bus 改为 Bus(input_spec, output_spec, ChannelFactory) + Injector，无 selector；runtime 为 channel_factory.zig、sync/notify 等（R36）
   - 所有 `_test.zig` 从 `src/` 迁移到 `test/unit/`，src 目录变为纯库代码
   - 根 build.zig 移除 test step，测试通过 `test/unit/` 独立包运行
   - 测试文件通过 `@import("embed")` 访问库公共 API
3. 对 cellular plan 的影响：
   - 所有 Mock 测试文件应放在 `test/unit/pkg/cellular/` 下，不在 `src/pkg/cellular/` 内联
   - 测试运行命令从 `zig test src/pkg/cellular/xxx.zig` 改为 `cd test/unit && zig build test`
   - Step 11 的 mod.zig 导出需同时更新 `test/unit/mod.zig`
   - 已更新 plan 中所有涉及文件表和测试命令
4. Q10（PPP/lwIP）仍然阻塞：main 的 channel_factory/selector 重构是 event bus 层面的，不是 cellular 所需的 uart/modem 统一 IO poll 重构，pkg/lwip 和 netlink 抽象也未添加

---

## 11. Open Questions

### 原有问题

- [x] Q1: uart.zig: need setBaudrate() for CMUX baud ramp in single-channel mode? **已解决（R27）**。setRate 作为 optional callback 放在 Modem.InitConfig 中（方案 B），与 PowerControl 同模式。Io 接口不变。enterCmux() 中按 AT+IPR → setRate → AT verify → AT+CMUX=0 顺序调用。USB/MockIo/CMUX 虚拟通道不受影响。
- [x] Q2: Thread safety: should Modem.dispatch() be thread-safe? **已解决（R32）**。Modem 不做线程安全。依据：pkg 内与 Cellular 同模式的外设（MotionPeripheral、Button）均为「驱动仅由单一线程访问」—— worker 线程独占 sensor/gpio，主线程只通过 rt.recv() 收事件、不碰驱动。Cellular 同理：Modem 由 Cellular 的 worker 独占，主线程只收 CellularEvent，不持有 Modem 引用。BLE Host 的 HCI 也仅由 Host 内部 readLoop/writeLoop 使用，不对 app 暴露。故 Modem 单线程使用即可。
- [x] Q3: Should modem.zig depend on pkg/flux/store.zig or embed minimal store? **已解决（R25）**。Modem 不再持有 Store。状态机和 reduce 移到 Cellular 层，Cellular 内部直接管理 ModemState，不依赖 flux Store。
- [x] Q4: pump() in single-channel mode: caller responsibility or internal thread? **已解决（R21+R25）**。CMUX pump 由 Modem 内部线程驱动。Cellular 的 worker 线程负责 pumpUrcs + 状态轮询 + 事件发射。
- [x] Q5: Package name: `cellular` confirmed? **已解决（R27）**。包名 `cellular`，内部 `modem/` 子目录为硬件驱动层抽象。

### R20 Review 发现的问题

**关键遗漏（阻塞开发）：**

- [x] Q6: Io poll/超时语义。**已解决（R21）**。详见下方实施规格。
- [x] Q7: 电源管理接口。**已解决（R22，R38 修正）**。详见下方实施规格。
- [x] Q8: Io close/flush。**已解决（R22）**。详见下方实施规格。
- [x] Q9: CMUX open() 职责。**已解决（R22）**。详见下方实施规格。

#### Q6 实施规格：Io poll/超时语义

**涉及文件：** `io/io.zig`, `at/engine.zig`, `at/cmux.zig`, `modem/modem.zig`

**1) io/io.zig — Io 接口增加 pollFn（必须字段）**

```zig
pub const PollFlags = packed struct {
    readable: bool = false,
    writable: bool = false,
    _padding: u6 = 0,
};

pub const Io = struct {
    ctx: *anyopaque,
    readFn:  *const fn (*anyopaque, []u8) IoError!usize,
    writeFn: *const fn (*anyopaque, []const u8) IoError!usize,
    pollFn:  *const fn (*anyopaque, i32) PollFlags,     -- 必须提供

    pub fn read(self: Io, buf: []u8) IoError!usize;
    pub fn write(self: Io, buf: []const u8) IoError!usize;
    pub fn poll(self: Io, timeout_ms: i32) PollFlags;   -- 等最多 timeout_ms 毫秒
};
```

- `read()` 语义：**非阻塞**。无数据返回 `error.WouldBlock`。
- `poll(timeout_ms)` 语义："等最多 N 毫秒，返回哪些操作就绪"。

各平台 pollFn 实现要求：

| Io 类型 | pollFn 实现 | 说明 |
|---------|------------|------|
| UART (ESP32) | 硬件中断 + RTOS 信号量等待 | 透传 HAL uart.poll() |
| USB 串口 (Linux/Mac) | POSIX `poll()` 系统调用 | 包装 fd poll |
| CMUX 虚拟通道 | `Notify.timedWait(timeout_ns)` | pump 线程 signal 后唤醒 |
| MockIo (测试) | 检查 rx 有未读数据 (`rx_pos < rx_len`)，忽略 timeout | 立即返回 |

MockIo 的 pollFn 示例：
```zig
fn mockPoll(ctx: *anyopaque, _: i32) PollFlags {
    const self = @ptrCast(*MockIo, @alignCast(ctx));
    return .{ .readable = self.rx_pos < self.rx_len, .writable = true };
}
```

CMUX 虚拟通道的 pollFn 示例：
```zig
fn cmuxChannelPoll(ctx: *anyopaque, timeout_ms: i32) PollFlags {
    const ch = @ptrCast(*ChannelBuf, @alignCast(ctx));
    if (ch.buffer.len > 0) return .{ .readable = true };
    const timeout_ns: u64 = @intCast(timeout_ms) * 1_000_000;
    const signaled = ch.notify.timedWait(timeout_ns);
    return .{ .readable = signaled and ch.buffer.len > 0 };
}
```

**2) at/engine.zig — AtEngine 使用 comptime Time + buf_size，统一 poll+read 循环**

```zig
pub fn AtEngine(comptime Time: type, comptime buf_size: usize) type {
    return struct {
        io: Io,
        time: Time,    -- 有 nowMs() 和 sleepMs() 方法
        rx_buf: [buf_size]u8,
        rx_pos: usize,
        ...
    };
}
```

AtEngine.send() 的超时循环伪代码：
```zig
pub fn send(self: *Self, cmd: []const u8, timeout_ms: u32) AtResponse {
    _ = self.io.write(cmd);
    const start = self.time.nowMs();
    while (true) {
        const elapsed = self.time.nowMs() - start;
        if (elapsed >= timeout_ms) return .{ .status = .timeout };
        const remaining: i32 = @intCast(timeout_ms - elapsed);
        _ = self.io.poll(remaining);
        const n = self.io.read(&self.rx_buf[self.rx_pos..]) catch |e| switch (e) {
            error.WouldBlock => continue,
            else => return .{ .status = .error },
        };
        self.rx_pos += n;
        if (self.tryParseResponse()) |resp| return resp;
    }
}
```

Time contract 要求（与 `runtime/time.zig` 一致）：
- `nowMs(self) -> u64`：返回毫秒时间戳
- `sleepMs(self, ms: u32) -> void`：休眠（AtEngine 当前不需要，但 Time contract 要求）

测试中传 FakeTime：
```zig
const FakeTime = struct {
    ms: u64 = 0,
    pub fn nowMs(self: *const FakeTime) u64 { return self.ms; }
    pub fn sleepMs(_: FakeTime, _: u32) void {}
};
```

**3) at/cmux.zig — pump 线程 + per-channel Notify**

CMUX 单通道模式的数据流：
```
物理 UART
    ↑ uart.poll() 等待数据（物理层 poll）
    |
pump 线程（独立 Thread，持续运行）
    ↓ 从 UART read → CMUX 解帧 → 写入对应 DLCI buffer → notify.signal()
    |
虚拟通道 Io
    ↑ channelIo.poll() = notify.timedWait()（业务层等待）
    |
AtEngine / lwIP（消费者）
```

pump 线程循环伪代码：
```zig
fn pumpLoop(self: *Self) void {
    while (self.active) {
        const flags = self.io.poll(10);    -- 物理层 poll，10ms 节拍（见 Q14 规格）
        if (!flags.readable) continue;
        const n = self.io.read(&self.rx_buf) catch continue;
        for (self.decodeFrames(self.rx_buf[0..n])) |frame| {
            if (self.channels[frame.dlci]) |*ch| {
                ch.buffer.write(frame.data);
                ch.notify.signal();          -- 唤醒在此通道等待的消费者
            }
        }
    }
}
```

pump 线程的启动/停止由 Modem.enterCmux()/exitCmux() 管理。

**Q14 实施规格：轮询周期与调用频率**

参考 quectel 项目与 pkg 下其他包的配置，建议取值如下。

| 来源 | 用途 | 取值 | 说明 |
|------|------|------|------|
| quectel (C) | 主任务/定时器 | 10ms | modem_test 中 LVGL 用 `timer_handler_period_ms=10`；CPIN 轮询 500ms 兜底；RSSI 默认 30s、示例 5s |
| quectel (C) | CMUX | ack_timer=10, frame_size=127 | 与 10ms 量级一致 |
| pkg/event button/motion | 按键/传感器轮询 | 10–20ms | `poll_interval_ms`: GPIO 10, ADC 10, motion 20 |
| pkg/event bus | 主循环 tick | 由应用传入 | `Bus.tick(time, interval_ms)`，应用决定 interval |
| pkg/ble host | HCI 可写等待 | 100ms | `hci.poll(.writable, 100)`，仅写前阻塞 |
| pkg/audio | 帧间隔 | ~10–20ms | `frameIntervalMs()` 驱动采集/播放 |

**建议配置：**

1. **Cmux pump 线程（物理 UART 读取）**  
   - **周期：10ms**（与 quectel 任务节拍、button 10ms 对齐）。  
   - 实现：`io.poll(10)` 或 `sleepMs(10)` 后读，避免长时间不读导致 UART 硬件/缓冲区溢出。  
   - 可配置：如 `pump_poll_ms: u32 = 10`，允许平台改为 20ms（如低功耗）。

2. **Cellular worker tick（pumpUrcs + 状态机）**  
   - **pumpUrcs 调用频率**：每次 `tick()` 内先 `pumpUrcs()` 再执行状态机与 Control 请求。  
   - **tick 间隔**：默认 **1000ms（1s）** 更稳妥；若仅做「状态/信号轮询」可设为 5000ms，但需保证 AT 通道 buffer 足够（见下）。  
   - 推荐：默认 `poll_interval_ms = 1000`，这样 1s 内约 100 次 pump 写入，AT 通道 buffer 建议 ≥ 4KB（单通道 CMUX 下）。

3. **调用顺序（单通道 CMUX）**  
   - 主循环：`rt.recv()` 得到事件（含 `.tick`）→ `rt.dispatch()` → 各事件源 `tick()`。  
   - Cellular.tick() 内顺序：**先 `at_engine.pumpUrcs()`**（从虚拟 AT 通道读入 URC 并分发）→ 再根据当前 phase 做 getStatus/getStrength/Control 等。  
   - Cmux.pump() 在**独立线程**中持续以 10ms 从物理 UART 读、解帧、写入各 DLCI buffer 并 notify；不依赖主循环周期。

4. **与 quectel 的差异**  
   - C 侧无独立 pump 线程，主任务在 AT 命令里阻塞读 UART，等效「按需读」。  
   - Zig 侧用独立 pump 线程 + 虚拟通道，需显式保证：pump 足够频繁（10ms）、消费者（pumpUrcs）至少每 1s 消费一次，避免 AT 通道积压。

pump 线程的启动/停止由 Modem.enterCmux()/exitCmux() 管理。

**4) 依赖的已有基础设施**

| 组件 | 位置 | 用途 |
|------|------|------|
| Thread contract | `runtime/thread.zig` | pump 线程 spawn/join |
| Notify contract | `runtime/sync.zig` | CMUX 通道 signal/timedWait |
| Time contract | `runtime/time.zig` | AtEngine 超时计算 |
| HAL PollFlags | `hal/uart.zig` | Io.PollFlags 定义对齐 |

**5) 内存估算（Q22）**

粗略公式（单通道 CMUX + AtEngine）：

- 每通道：`ChannelBuf` 约 2KB × `max_channels`（可配置，见 5.6）。
- AtEngine：单块 `[buf_size]u8`，默认 1024，长响应可 2048（R40）。
- Cmux：pump 线程栈 + 解码用临时 buffer，量级数百字节。

示例：`max_channels=2`、`buf_size=1024` 时约 2×2KB + 1KB ≈ 5–6KB；ESP32 通常可接受。**此为估算，真机需实测；若 RAM 紧张可减小单通道 buffer 或 buf_size。**

---

#### Q7 实施规格：电源管理接口（R38 修正）

**涉及文件：** `modem/modem.zig`（Modem 签名加 `comptime Gpio`，InitConfig 内定义 PowerPins）

**设计原则：** 项目已有完整 HAL trait 抽象（`hal/gpio.zig` 的 `from(spec)` + `is()` 模式），
PowerControl 应对齐此模式，而非使用函数指针。与 `pkg/event/button` 注入 `comptime Gpio` 的方式一致。

**PowerPins 定义（替代旧 PowerControl）：**

```zig
pub const PowerPins = struct {
    power_pin: ?u8 = null,    -- enable/disable supply (OutputPin behavior)
    reset_pin: ?u8 = null,    -- hardware reset pulse (OutputPin behavior)
    vint_pin: ?u8 = null,     -- power status feedback (InputPin, read-only)
};
```

放在 `Modem.InitConfig` 中：
```zig
pub const InitConfig = struct {
    ...
    gpio: ?*Gpio = null,      -- 可选，null = 无硬件引脚控制
    pins: PowerPins = .{},    -- 默认全 null
    ...
};
```

**Modem 内部使用方式：**

```zig
-- 上电（powerUp）：
pub fn powerUp(self: *Self) !void {
    const g = self.gpio orelse return;
    const pin = self.pins.power_pin orelse return;
    try g.setLevel(pin, .high);
    self.time.sleepMs(100);
    -- 如果有 vint_pin，轮询确认上电成功
    if (self.pins.vint_pin) |vp| {
        var attempts: u8 = 0;
        while (attempts < 20) : (attempts += 1) {
            const lv = g.getLevel(vp) catch break;
            if (lv == .high) return;
            self.time.sleepMs(100);
        }
        return error.PowerUpTimeout;
    }
}

-- 硬件复位（hardReset）：
pub fn hardReset(self: *Self) !void {
    const g = self.gpio orelse return;
    const pin = self.pins.reset_pin orelse return;
    try g.setLevel(pin, .low);
    self.time.sleepMs(300);
    try g.setLevel(pin, .high);
}

-- 断电（powerDown）：
pub fn powerDown(self: *Self) void {
    const g = self.gpio orelse return;
    const pin = self.pins.power_pin orelse return;
    g.setLevel(pin, .low) catch {};
}

-- 电源状态查询：
pub fn isPowered(self: *Self) ?bool {
    const g = self.gpio orelse return null;
    const vp = self.pins.vint_pin orelse return null;
    const lv = g.getLevel(vp) catch return null;
    return lv == .high;
}
```

**各平台实现示例：**

ESP32 (auto-start 模式，仅供电使能)：
```zig
const EspGpio = hal.gpio.from(.{ .Driver = esp_gpio.Driver, .meta = .{ .id = "esp-gpio" } });
var gpio_driver: esp_gpio.Driver = .{};
var gpio = EspGpio.init(&gpio_driver);

const modem = Modem(Thread, Notify, Time, quectel, EspGpio, 1024).init(.{
    .io = uart_io,
    .time = time,
    .gpio = &gpio,
    .pins = .{ .power_pin = MODEM_ENABLE_PIN },
});
```

ESP32 (PWRKEY + RESET + VINT 全引脚)：
```zig
const modem = Modem(Thread, Notify, Time, quectel, EspGpio, 1024).init(.{
    .io = uart_io,
    .time = time,
    .gpio = &gpio,
    .pins = .{
        .power_pin = PWRKEY_PIN,
        .reset_pin = RESET_PIN,
        .vint_pin = VINT_PIN,
    },
});
```

Linux/Mac USB、测试 Mock（无 GPIO 控制）：
```zig
-- Gpio 类型仍需提供（comptime 参数），但实例传 null
const MockGpio = hal.gpio.from(.{ .Driver = mock_gpio.Driver, .meta = .{ .id = "mock-gpio" } });
const modem = Modem(Thread, Notify, Time, quectel, MockGpio, 1024).init(.{
    .io = usb_io,
    .time = time,
    .gpio = null,     -- 无硬件引脚控制
    .pins = .{},
});
```

---

#### Q8 实施规格：Io 不加 close/flush

**结论：Io 接口保持 read/write/poll 三个操作，不加 close 和 flush。**

**close 不需要的原因：**
- Io 的生命周期由调用方管理（谁创建谁释放）
- Modem 不应该释放调用方传入的 Io 资源
- 与 C 代码一致：`quectel_task_stop()` 不 close UART，UART 由 board 层管理

**flush 不需要的原因：**
- 所有模式切换都有 AT command-response 作为天然同步点
- 发 AT+CMUX=0 → 等 OK：模组回 OK 时命令字节一定已全部从物理线路发出
- 退出 CMUX 发 DISC → 等 UA/DM：同理
- 退出数据模式 +++ → 等 OK：同理
- 因此不存在"写了数据不等回复就要切换模式"的场景

**对实施者的影响：**
- `io/io.zig` 无需实现 close/flush
- `io/mock.zig` 无需实现 close/flush
- `fromUart()` / `fromSpi()` 无需映射 close/flush
- CMUX virtual channel Io 无需实现 close/flush

---

#### Q9 实施规格：CMUX open() 职责分离

**结论：AT+CMUX=0 由 Modem 通过 AtEngine 发送，Cmux.open() 只做 SABM/UA 握手。**

**Modem.enterCmux() 完整流程（单通道模式）：**  
DLCI 列表与 at/ppp 绑定均来自 `config.cmux_channels`（见 5.6.1 可配置通道实施规格）。以下以默认配置（dlci 1=ppp、2=at）为例说明步骤。

```
Step 1: Modem 用 AtEngine 发送 AT+CMUX=0
        self.at_engine.send("AT+CMUX=0", 5000)
        → 收到 OK → 此时模组已切换到 CMUX 帧模式
        → 从此刻起物理 UART 上只能走 CMUX 帧，不能发裸 AT 了

Step 2: Modem 调用 Cmux.open() 做 SABM/UA 握手
        dlcis = 从 config.cmux_channels 收集各条 dlci（如 [1, 2]）
        self.cmux.open(dlcis)
        → 内部：发 SABM DLCI=0 帧 → 等 UA 帧（控制通道）
        → 内部：对 dlcis 中每个 DLCI 发 SABM → 等 UA（如 DLCI=1 PPP、DLCI=2 AT）

Step 3: Modem 启动 pump 线程
        self.cmux.startPump()
        → pump 线程开始持续从物理 UART 读帧、解码、分发到各通道 buffer

Step 4: Modem 把 AtEngine 的 Io 切换到 CMUX AT 虚拟通道
        at_dlci = config.cmux_channels 中 role == .at 的那条的 dlci
        const at_ch_io = self.cmux.channelIo(at_dlci);
        self.at_engine.setIo(at_ch_io);
        → 此后 at_engine.send() 的数据走该 DLCI

Step 5: PPP 数据通道就绪
        ppp_dlci = config.cmux_channels 中 role == .ppp 的那条的 dlci
        self.data_io = self.cmux.channelIo(ppp_dlci);
        → modem.pppIo() 返回该 DLCI 的 Io
```

**Modem.exitCmux() 完整流程（单通道模式）：**

```
Step 1: 恢复 AtEngine Io 到原始物理 UART（先停止通过 CMUX AT 通道发命令）
Step 2: 停止 pump 线程 self.cmux.stopPump()
Step 3: 关闭 CMUX self.cmux.close() → 发 DISC 帧
Step 4: 等模组退出 CMUX 模式（可能需要短暂 delay）
Step 5: AT 引擎恢复到直连物理 Io，发 AT 验证模组正常
```

**Multi-channel 模式：** enterCmux()/exitCmux() 均为 no-op（通道已天然分离）。

**各组件职责边界：**

| 组件 | 知道什么 | 不知道什么 |
|------|---------|----------|
| AtEngine | AT 命令格式、响应解析、URC | CMUX 帧格式、通道概念 |
| Cmux | SABM/UA/DISC/UIH 帧编解码、通道复用 | AT 命令、AT+CMUX=0 |
| Modem | 两者的编排顺序、状态机 | 具体协议细节 |
- [~] Q10: PPP/lwIP 集成接口。**暂缓 — 等待 main 分支重构。** main 分支即将进行统一 IO poll 重构（uart/ble/hci/wifi/modem），并在 pkg 下新增 lwip Zig 绑定实现用户态网络栈，通过 netlink 抽象（WiFi 或 modem）发送数据。重构后 cellular 的 Io 接口和 PPP/lwIP 集成方式都将改变。当前结论：pkg/cellular 边界到 pppIo()（与 WiFi HAL 无 lwIP 集成的模式一致），PPP 协商和 lwIP 对接由外部 pkg/lwip 处理。具体接口待 main 重构完成后对齐。

**设计深度不足：**

- [x] Q11 / R44：`registered` 与 `dialing` 分离；`dial_requested` → `dialing`；`dial_failed` → `registered`。
- [x] Q12: AtResponse 缓冲区硬编码 [8][128]u8。**已解决（R40）**。改为单一平坦缓冲区 `[buf_size]u8`，大小由 `comptime buf_size` 控制。AtResponse.body 为 rx_buf 内切片 + lineIterator。溢出返回 `AtStatus.overflow`。参考 atat const generic + esp_modem dte_buffer_size 设计。
- [x] Q13 / R30：`retry` 由应用 dispatch；reducer：`error` + `retry` → `probing`，清零计数与 `error_reason`。
- [x] Q14: URC pump 调度策略未定义。**已解决**。见下「Q14 实施规格：轮询周期与调用频率」。
- [x] Q15: MockIo.onSend() 自动应答器设计模糊。**已解决（R42 修正）**。移除 `onSend()` 自动应答，与 BLE `MockHci` 对齐，只保留 FIFO `feed()`。理由：(1) tick 改为按 phase 每次只发一条 AT（对齐 quectel C / ublox-rs / Zephyr），FIFO feed 即可覆盖所有场景；(2) BLE MockHci 也只有 `injectPacket` 无自动应答，已验证可行；(3) 复杂流程用 `feedSequence()` 辅助函数一次性预填。
- [x] Q16: sim.zig registerUrcs(dispatch_ctx: anytype) 的 anytype 是 comptime 参数，但 URC 回调是运行时注册的，签名可能有实现问题。**已解决**。Zig 的 anytype 在调用点推断，每个 call site 的 dispatch_ctx 类型 comptime 已知；registerUrcs 在 init 时调用一次，AtEngine 内以函数指针+ctx 保存，调用时传 ctx。实现时对 dispatch_ctx 做 comptime 接口约束即可，签名可行。

**过度设计：**

- [x] Q17: voice.zig 是否应从 Phase 2 移除？**保留**。voice 为业务层（基于 commands 层的 ATD/ATA/ATH 等封装 dial/answer/hangup），Phase 2 保留 voice.zig；后续视需求再决定是否拆分或迁到别处。
- [x] Q18: fromSpi() 是否降级为按需添加？**不降级**。UART、SPI、USB 均在 Io 层做 comptime 抽象（fromUart/fromSpi 及多通道 USB 用法），接口与实现规划都保留；**真机/烧录验证 Phase 1 先只做 UART**，SPI/USB 真机测试后续按需补。
- [x] Q19: Cmux comptime max_channels 泛型是否简化？**不简化**。由用户在实例化时配置：`Cmux(Thread, Notify, max_channels)`，传 2、3 或 4 等（常见 4G 模组上限为 4，esp_modem/Quectel 典型用 2）。不做成写死常量。
- [x] Q20: CmuxChannelConfig/CmuxChannelRole 可配置性是否过度？**已解决（R41）**。保留可配置：CMUX 各通道的 DLCI 与用途（AT/PPP）由模组或用户约定，不同模组/固件可能不同，用户必须能配置。实现上：ModemConfig.cmux_channels 驱动 enterCmux 的 open(dlcis) 与 at/ppp 通道绑定；init 时校验「恰好一个 .at、一个 .ppp、dlci 不重复且合法」。详见 5.6.1 可配置通道实施规格。

**可行性风险：**

- [x] Q21: CMUX 实现复杂度可能被低估。**已收敛**。承认风险；Phase 1 维持 10 个测试覆盖帧编解码、SABM/UA/DISC、通道隔离。实现中若发现帧同步、流控、错误恢复有缺口，在对应 Step 追加测试（如 MX-11～），不在此写死数量。
- [x] Q22: 内存使用评估缺失。**已解决**。在 at/cmux.zig（pump 线程）小节下增加「5) 内存估算（Q22）」：每通道 buffer×max_channels + AtEngine buf_size + 栈；示例 2 通道约 5–6KB，标注为估算、真机需测。

**R25 新增：**

- [x] Q23: Cellular.tick() 的错误处理策略。**已解决（R35/6.1）**。tick() 只根据 modem/sim/signal 结果推断并 dispatch 事件（如 at_timeout、sim_error），不在此处做「第几次才报错」判断；是否进 error、at_timeout_count 与阈值逻辑全部在 reducer 内完成。不同错误类型通过 ModemEvent 变体区分，reducer 按 phase + 事件决定转换。
- [x] Q24: CellularPayload 的事件粒度。**已解决**。首版维持当前五种（phase_changed / signal_updated / sim_status_changed / registration_changed / error），后续按需求再拆（如区分 at_timeout 与 cmux_failed）或收敛（如 state_changed + 快照）。
- [x] Q25 / R33：C 侧 WAIT_SIM → SIM ready → CMUX；Zig 侧在 **CPIN ready 已上报之后**（`registering` 及以后）再 enterCmux；失败 → error，`retry` → probing。

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

### 结论（R21 确定）

经过四个子问题逐一推导，最终方案：

**Q6-d：谁驱动 pump**
→ 独立线程。仅 CMUX 单通道模式需要。利用已有的 `runtime/thread.zig` contract 实现跨平台兼容。
USB 多通道模式不需要 pump 线程。

**Q6-c：AtEngine 等待策略**
→ 统一用 `io.poll(remaining_ms)` → `io.read(buf)` 循环。AtEngine 不需要知道底层是物理 Io 还是虚拟 Io。
CMUX 虚拟通道的 pollFn 内部用 `Notify.timedWait()` 实现（pump 线程解帧后调用 `notify.signal()` 唤醒）。

**Q6-a：read() 语义**
→ 非阻塞。无数据返回 `WouldBlock`。调用方先 poll 等就绪再 read。与 HAL uart.zig 行为一致。

**Q6-b：时间源**
→ AtEngine 接受 comptime `Time` 类型参数，内部用 `self.time.nowMs()` 计算剩余超时。
各平台注入：std 用 `runtime.std.Time`，ESP32 用 board time，测试传 `FakeTime`。

**pollFn 修正为必须**
原方案 D（可选 pollFn）修正为方案 A 方向（必须提供）。原因：如果 CMUX 虚拟通道也通过 Notify 包装为 pollFn，
则 AtEngine 只需一条代码路径，接口统一。各 Io 实现方式不同但语义相同："等最多 N 毫秒，告诉我有没有数据。"

**风格对齐**
Time/Thread/Notify 通过 comptime 类型参数注入，与现有 pkg 模块一致
（button, timer, motion, audio engine 均使用此模式）。
Io 仍然是 type-erased（运行时 CMUX 切换需求），这是 cellular 特有的合理例外。

**依赖的已有基础设施：**
- `runtime/thread.zig`：Thread contract（spawn/join/detach）
- `runtime/sync.zig`：Notify contract（signal/wait/timedWait）
- `runtime/time.zig`：Time contract（nowMs/sleepMs）
- `runtime/std/time.zig`：Time std 实现
- `hal/uart.zig`：PollFlags + poll(flags, timeout_ms)
