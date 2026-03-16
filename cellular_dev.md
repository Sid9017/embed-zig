# pkg/cellular 开发设计文档（cellular_dev）

> 本文档是 **pkg/cellular** 模块的单一事实来源，供多工程师按目录树分层实现与验收。
> 来源：plan.md（设计规格 + 实施步骤）+ plan-review.md（拍板决策与实现细节回填）。

---

## 目录

1. [文档说明与目标](#1-文档说明与目标)
2. [架构总览](#2-架构总览)
3. [目录树与按层级的设计文档](#3-目录树与按层级的设计文档)
4. [实施顺序与通过标准](#4-实施顺序与通过标准)
5. [已拍板决策汇总](#5-已拍板决策汇总)
6. [实现中若遇不明确处](#6-实现中若遇不明确处)

---

## 1. 文档说明与目标

- **读者**：实现 cellular 的工程师（可能多人并行）。
- **目标**：按本文档可独立完成各层实现与单测/烧录验证，无需反复查阅 plan.md / plan-review.md。
- **约定**：所有「实现细节」来自 plan 的 Open Question 结论与 plan-review 的拍板项，已回填到对应模块小节。若在实现某模块时发现规格不清或冲突，**先停下来在 6 中记录并询问**，再继续。

---

## 2. 架构总览

### 2.1 架构图（高层）

```
+-----------------------------------------------------------+
|  Application (AppRuntime)                                  |
|    loop: r = rt.recv(); rt.dispatch(r.value); if dirty -> render |
+-----------------------------------------------------------+
|  Injector boundary                                        |
|  Cellular 通过 bus.Injector(.cellular) 拿到 EventInjector，  |
|  在 tick 内 injector.invoke(CellularPayload) 推事件入 Bus。  |
+-----------------------------------------------------------+
|  pkg/cellular/                                            |
|    cellular.zig  事件源 + 状态机                           |
|    types.zig     共享类型（含 CellularPayload）            |
|    modem/        Modem 驱动；sim/signal；quectel/simcom     |
|    at/           引擎、命令、解析、CMUX、URC                |
|    io/           Io 接口、Trace、MockIo                     |
+-----------------------------------------------------------+
|  Io boundary（纯 Zig 与 平台相关 分界）                     |
+-----------------------------------------------------------+
|  Platform: UART/SPI/USB -> Io; Test: MockIo (linear buffers)|
+-----------------------------------------------------------+
```

### 2.2 层级图（与目录一一对应）

```
+-----------------------------------------------------------+
|  Application (AppRuntime)                                  |
|    loop: r = rt.recv(); rt.dispatch(r.value); if dirty -> render |
+-----------------------------------------------------------+
|  Injector boundary                                        |
|  Cellular 通过 bus.Injector(.cellular) 拿到 EventInjector，  |
|  在 tick 内 injector.invoke(CellularPayload) 推事件入 Bus。  |
+-----------------------------------------------------------+
|  pkg/cellular/                                            |
|    cellular.zig -- event source + state machine            |
|    types.zig -- shared types (incl. CellularPayload)        |
|    modem/   modem.zig, sim.zig, signal.zig, quectel*, simcom* |
|    at/      engine.zig, commands.zig, parse.zig, cmux.zig, urcs.zig |
|    io/      io.zig, trace.zig, mock.zig                     |
+-----------------------------------------------------------+
|  Io boundary（以上纯 Zig；以下平台相关）                    |
+-----------------------------------------------------------+
|  ESP32/Beken: UART -> Io  |  Linux/Mac: USB at_io+data_io  |
|  Test: MockIo (linear buffers)                             |
+-----------------------------------------------------------+
```

### 2.3 事件流（Worker vs Main）

Worker：pumpUrcs / sim.getStatus / signal.getStrength → 更新 phase → 若变化则 injector.invoke(payload)；并处理 Control 请求写 response。Main：rt.recv() → dispatch → isDirty 则 drive outputs。无 selector.poll。

### 2.4 运行模式（Modem）

- **Single-channel**：只提供 io，内部 CMUX 拆 AT + PPP。
- **Multi-channel**：提供 at_io + data_io，不用 CMUX。自动判定：data_io != null 即 multi。

### 2.5 Runtime 合约（Thread / Notify / Time）

来自 runtime/thread.zig、runtime/sync/notify.zig、runtime/time.zig；comptime 注入。Thread：spawn/join/detach。Notify：init/deinit/signal/wait/timedWait。Time：nowMs/sleepMs。request_queue/response_channel 用 runtime/channel_factory。

---

## 3. 目录树与按层级的设计文档

```
src/pkg/cellular/
├── types.zig
├── cellular.zig
├── io/  (io.zig, trace.zig, mock.zig)
├── at/  (engine.zig, commands.zig, parse.zig, cmux.zig, urcs.zig)
└── modem/  (modem.zig, sim.zig, signal.zig, quectel.zig, simcom.zig, quectel_stub.zig)
```

### 3.1 types.zig

**职责**：共享类型，无逻辑、无 IO。导出：Phase, SimStatus, NetworkType, RegistrationStatus, CallState, ModemError；SignalInfo, **ModemInfo**, SimInfo, ModemState, ModemEvent, ConnectConfig, ChannelConfig, ModemConfig；Control 相关（见 3.2）。

**实现细节**：全库统一 **ModemInfo**；命令名可叫 GetModuleInfo，Response 为 types.ModemInfo。ModemConfig 含：cmux_channels（默认 `&.{ .{ .dlci = 1, .role = .ppp }, .{ .dlci = 2, .role = .at } }`）、cmux_baud_rate、at_timeout_ms、max_urc_handlers、**context_id: u8 = 1**。Control 类型（可放在 types 或 cellular 并导出）：SEND_AT_BUF_CAP=256；SendAtPayload{ buf, len }；ControlRequestTag / ControlRequest（get_signal_quality, send_at: SendAtPayload）；ControlResponse（signal_quality: SignalInfo, at_ok, at_error: AtStatus, timeout, uninitialized）。

**测试**：types_test.zig，3 个。

### 3.2 cellular.zig

**职责**：事件源 + 状态机。持 Modem、injector、request_queue、response_channel、state。仅**生命周期路径** AT 驱动 reducer；Control 请求结果只写 response，不送 reducer。

**Control 实现细节（拍板）**：AtError 方案 A（at_error 携带 AtStatus，API 返回 error.AtError/Timeout）。SendAtPayload：buf[256]+len，len<=256；超长返 error.PayloadTooLong；Worker 用 buf[0..len]。request_queue：channel_factory，容量 4～8。response_channel：单槽，capacity 0 或 1。6.1.1 硬性约束：Control 超时/错误绝不送 reducer、不增加 at_timeout_count。

**Reducer 规则摘要**（仅生命周期路径驱动）：starting + at_timeout → at_timeout_count++，≥3 则 phase=error, error_reason=at_timeout；starting + at_ready → at_timeout_count=0, phase=ready；ready/sim_ready/… + sim_error 等 → error + error_reason；error + retry → phase=starting, error_reason=null, at_timeout_count=0。tick() 只推断并 dispatch 事件，计数与阈值逻辑均在 reducer 内。

**Worker 内 Control 处理**：每次 tick 之后 tryRecv(request_queue)。若 phase==.off 则 response.send(.uninitialized)。否则：get_signal_quality → signal.getStrength()，结果写 response（不 reduce）；send_at → 仅用 payload.buf[0..payload.len] 调 sendRaw，结果写 response（不 reduce）。超时只 response.send(.timeout)，不派发 ModemEvent。

**测试**：cellular_test.zig — reducer 21 + 事件 7 + Control 3（CT-01～CT-03）。

### 3.3 io/io.zig

**职责**：类型擦除 Io，read 非阻塞（WouldBlock），**pollFn 必选**。fromUart/fromSpi。无 fromBufferPair/RingBuffer。**测试**：io_test.zig，3 个。

### 3.4 io/trace.zig

**职责**：装饰器 wrap(inner, log_fn)，记录 tx/rx。**测试**：trace_test.zig，4 个。

### 3.5 io/mock.zig

**职责**：测试用传输。**实现细节**：**两段线性 buffer**，无 RingBuffer；tx_buf/tx_len、rx_buf/rx_len/rx_pos；feed/sent/drain；**无 onSend()**，用 feedSequence 多步。**测试**：被 io/engine/cmux 等测试复用。

### 3.6 at/parse.zig

**职责**：纯解析函数，依赖 types。isOk, isError, parseCmeError, parseCmsError, parsePrefix, parseCsq, parseCpin, parseCreg, rssiToDbm, rssiToPercent。**测试**：parse_test.zig，11 个。

### 3.7 at/commands.zig

**职责**：类型化 AT 命令。合约：Response, prefix, timeout_ms, write, **parseResponse(line)**（名称统一）, 可选 match。**实现细节**：方法名统一 **parseResponse**。**测试**：commands_test.zig，8 个。

### 3.8 at/engine.zig

**职责**：AT 引擎，Io+Time+buf_size。AtStatus, AtResponse（平坦 rx_buf 切片 + lineIterator）, sendRaw/send(Cmd)。**测试**：engine_test.zig，11 个。

### 3.9 at/cmux.zig

**职责**：GSM 07.10 CMUX，独立线程 pump，每通道 Notify。**实现细节（R41）**：ModemConfig.cmux_channels 配置 DLCI 与 at/ppp；init 校验恰好一 at 一 ppp；enterCmux 用 config 绑定。默认 dlci 1=ppp、2=at。**测试**：cmux_test.zig，10 个。

### 3.10 at/urcs.zig

**职责**：类型化 URC，prefix + parseUrc。**测试**：urcs_test.zig，5 个。

### 3.11 modem/modem.zig

**职责**：硬件驱动，无状态机。comptime Module, Gpio, Thread, Notify, Time, at_buf_size。init 校验 cmux_channels（单通道）。**Step 8 实现细节**：用**占位 Module**（quectel_stub.zig，仅 Probe 等）+ **gpio=null**；完整 Module Step 12。**测试**：modem_test.zig，13 个（Step 8 先跑非 CMUX 子集）。

### 3.12 modem/sim.zig、signal.zig

**职责**：通过 AtEngine 发 AT（SIM 状态/IMSI/ICCID、信号/注册/网络类型）。**测试**：sim_test 7、signal_test 7。

### 3.13 modem/quectel.zig、simcom.zig、quectel_stub.zig

**Module 契约**：commands、urcs、init_sequence。Response 用 types.ModemInfo。quectel_stub 仅 Step 8，Step 12 由 quectel.zig 替代。**测试**：quectel_test、simcom_test 各 4 个。

---

## 4. 实施顺序与通过标准

| Step | 内容 | 验证 | Mock 数 | 里程碑/通过标准 |
|------|------|------|---------|-----------------|
| 0 | 基础设施 | 烧录 | 0 | UART 收发 AT |
| 1 | types.zig | Mock | 3 | 3 passed |
| 2 | io.zig | 烧录 | 3 | Io 透传 |
| 3 | parse.zig | Mock+可选烧录 | 11 | 11 passed |
| 4 | engine+commands | 烧录 | 19 | 里程碑 #1 |
| 5 | sim.zig | 烧录 | 7 | 7+真机 SIM |
| 6 | signal.zig | 烧录 | 7 | 7+真机信号 |
| 7 | cellular reducer | Mock+可选烧录 | 21 | 21 passed |
| 8 | modem 路由 | 烧录 | 13 | 占位 Module+gpio=null |
| 9 | cmux.zig | 烧录 | 10 | 里程碑 #2 |
| 10 | modem 完整 | 烧录 | 4 | 里程碑 #3 |
| 11 | cellular 事件源+Control | 烧录 | 10 | 事件+CT-01～03 |
| 12 | quectel/simcom | Mock | 8 | 8 passed |
| 13 | mod.zig 导出 | Mock | 0 | **121 tests 全过** |

总体验收：`cd test/unit && zig build test` → 121 tests passed。Step 13 需在 **test/unit/mod.zig** 中新增 cellular 各测试文件的 `@import("pkg/cellular/...")` 条目，避免漏加或重复。**待定**：具体条目列表是否写入本文档，稍后决定。

---

## 5. 已拍板决策汇总

| # | 决策项 | 结论 |
|---|--------|------|
| 1 | 类型命名 | ModemInfo 统一；GetModuleInfo 的 Response=ModemInfo |
| 2 | Mock 传输 | 两段线性 buffer，无 RingBuffer，无 onSend |
| 3 | AtError | at_error 携带 AtStatus，API 返 error.AtError/Timeout |
| 4 | SendAtPayload | buf+len 256，超长 PayloadTooLong，Worker 用 buf[0..len] |
| 5 | request/response 通道 | channel_factory；request 4～8；response 单槽 0 或 1 |
| 6 | Step 8 | 占位 Module+gpio=null；完整 Module Step 12 |
| 7 | Thread/Notify/Time | comptime 注入，见 §2.5 |
| 8 | 文档统一 | parse.zig/engine.zig 标题；21 tests；parseResponse 合约 |

---

## 6. 实现中若遇不明确处

若某模块实现时发现规格缺失、与 plan/review 不一致或与现有代码对接不清，**先在此记录并暂停该处实现**，向维护者确认后再继续。

**当前预留（实现择一）**：response_channel capacity 取 0 或 1；request_queue 容量取 4 或 8。

---

*基于 plan.md Round 42 + plan-review.md 2026-03-16 整理。*
