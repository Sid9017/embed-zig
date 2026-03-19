# Step 8 补齐开发计划（可操作）

> 目标：按 plan.md Step 8 验收项补齐 modem 路由逻辑、UT/Mock、固件烧录段落，便于 review 后按条执行。

---

## 一、范围与不做的边界

- **本计划覆盖**：无效 init 报错、multi-channel 下保存并返回 `data_io`（`pppIo()`）、显式 mode、Step 8 约定 Mock 用例（MD-01～07、MD-12）、固件 `[step8]` 烧录验证段落。
- **本计划不覆盖**：CMUX 实现（Step 9）；单通道下 `enterDataMode` 发 ATD*99#（Step 10）；MD-08～MD-11。MD-13 在 Step 8 内仅验证「multi 下 pppIo 可用」，不实现 `enterDataMode()` API。

---

## 二、任务列表（按推荐执行顺序）

### 阶段 1：modem.zig 核心逻辑

| # | 任务 | 说明 | 涉及文件 |
|---|------|------|----------|
| 1.1 | **无效 init 报错** | 当 `io == null && at_io == null` 时，`init` 不得静默使用内部 stub，应返回错误。API：`init(cfg) InitError!Self`；**在 modem.zig 的 `Modem()` 返回的 struct 内**新增 `pub const InitError = error{ NoIo }`。调用方（固件、UT）需 `try Modem.init(...)`。 | `src/pkg/cellular/modem/modem.zig` |
| 1.2 | **保存 data_io** | 在 `Modem` 结构体内增加字段保存 `cfg.data_io`（类型 `?io.Io`），在 `init` 中赋值。 | `src/pkg/cellular/modem/modem.zig` |
| 1.3 | **pppIo() 实现** | `pppIo()`：若 `self.data_io != null` 返回该 Io，否则 `null`。单通道（仅 io）时保持 `null`；双通道（提供 data_io）时返回 data_io。 | `src/pkg/cellular/modem/modem.zig` |
| 1.4 | **暴露 mode（可选）** | 提供 `pub fn mode(self: *const Self) enum { single_channel, multi_channel }`：`data_io != null` → `multi_channel`，否则 `single_channel`。便于 UT 断言与固件日志。 | `src/pkg/cellular/modem/modem.zig` |

**验收**：编译通过；现有 `modem_test` 需适配 1.1（`try init` / 期望错误）。

---

### 阶段 2：单元测试（按 plan MD-xx）

| # | 测试 ID | 验证内容 | 说明 |
|---|---------|----------|------|
| 2.1 | MD-03 | invalid init | 不提供 `io` 且不提供 `at_io` 时，`Modem.init(...)` 返回错误（如 `NoIo`），不崩溃。 |
| 2.2 | MD-01 | single-ch init | 仅提供 `.io` 时，init 成功；可选：`mode() == .single_channel` 或 at() 写入的 mock 为该 io。 |
| 2.3 | MD-02 | multi-ch init | 提供 `.at_io` + `.data_io` 时，init 成功；`mode() == .multi_channel`。 |
| 2.4 | MD-07 | multi-ch pppIo available | 双通道 init 后 `pppIo() != null`。 |
| 2.5 | MD-06 | multi-ch PPP | 双通道下对 `pppIo().?.write("x")` 写入，断言：仅 data_io 的 mock 收到字节，at_io mock 的 `sent()` 长度不变。 |
| 2.6 | MD-04 | single-ch AT | 已有：at() 写向唯一 io 并收到 OK；可保留或加注释对应 MD-04。 |
| 2.7 | MD-05 | multi-ch AT | 已有「prefers at_io over io」；可保留或加注释对应 MD-05。 |
| 2.8 | MD-12 | multi-ch enterCmux noop | 双通道下调用 `enterCmux()`，不崩溃；再次 `pppIo()` 仍为 data_io（未变）。 |

**说明**：MD-13 在 Step 8 仅要求 multi 下 pppIo 可用，已由 MD-07/MD-06 覆盖；不实现 `enterDataMode()`。

**验收**：仓库根目录执行 `zig build test-cellular`，cellular 相关全过。若只跑 modem 子集：`cd test/unit && zig build test -- --test-filter "modem"`。

---

## 二（续）各阶段详细说明与背景

下面按阶段说明：**具体要改什么**、**在整体设计里处于什么位置**、**为什么要这么做**。

---

### 阶段 1 详解：modem.zig 核心逻辑

**背景：Modem 的两种用法**

4G 模组和主机之间通常有两种接法：

- **单通道（Single-channel）**：只有一根 UART（或一根 SPI）。AT 指令和 PPP 数据**共用这一根线**，必须靠 **CMUX**（GSM 07.10 多路复用）在一条物理链路上拆出「AT 通道」和「PPP 通道」。Step 8 时 CMUX 还没做（Step 9 才做），所以单通道下 **PPP 通道暂时不存在**，`pppIo()` 理应返回 `null`。
- **双通道（Multi-channel）**：例如 USB 模组暴露两个串口（ttyUSB2=AT、ttyUSB3=PPP）。应用分别传 `at_io` 和 `data_io`，Modem **不需要 CMUX**，AT 只走 at_io，PPP 只走 data_io。

plan 的约定是：**有没有提供 `data_io` 决定模式**——`data_io != null` 即 multi-channel，否则 single-channel。Modem 的职责就是「把 AT 打到对的 Io、把 PPP 打到对的 Io」，这就是 **Step 8 的“路由”含义**。

---

**1.1 无效 init 报错 — 为什么要做**

当前实现里，如果调用方既没传 `io` 也没传 `at_io`，`init` 会悄悄使用一个**内部 stub Io**（读总是 WouldBlock、写假装成功）。结果是：**init 永远“成功”**，但后续 `at().send()` 永远拿不到真实响应。这是**配置错误被掩盖**，在真机上会表现为“模组无响应”，难以排查。

**所以要做的**：在 `init` 里显式校验：若 `io == null && at_io == null`，**立即返回错误**（例如 `InitError.NoIo`），不落进 stub。`InitError` 定义在 **modem.zig 中 `Modem()` 返回的 struct 内**（如 `pub const InitError = error{ NoIo }`），调用方用 `ModemT.InitError` 做 `try` / `catch`。这样：

- 配置错误在**创建 Modem 时**就暴露；
- 所有调用 `Modem.init` 的代码必须处理 `try Modem.init(...)`，不会误以为“初始化成功”却用了一条假通道。

这对应 plan 的 **MD-03：invalid init → 返回错误**。

---

**1.2 保存 data_io — 为什么要做**

`InitConfig` 里已经有 `data_io: ?io.Io`，但今天 Modem 结构体**没有字段保存它**，init 时也没有把 `cfg.data_io` 存起来。双通道场景下，上层要拿「PPP 用的那条 Io」只能通过 `modem.pppIo()`；若 Modem 不保存 `data_io`，`pppIo()` 就没办法返回它。

**所以要做的**：在 Modem 里增加一个成员（例如 `data_io: ?io.Io`），在 `init` 里赋值为 `cfg.data_io`。这样后续 `pppIo()` 才能根据“是否提供了 data_io”决定返回什么。

---

**1.3 pppIo() 实现 — 为什么要做**

plan 和架构文档里约定：

- **Single-channel**：PPP 要等 CMUX 建链后才存在，Step 8 不做 CMUX，所以 `pppIo()` 应返回 `null`。
- **Multi-channel**：应用已经提供了独立的 data 口，Modem 应把这条 Io 原样暴露给上层（给 lwIP PPP 或后续 pkg 用），即 `pppIo() != null` 且写进去的字节**只出现在 data_io 上**。

当前 `pppIo()` 固定返回 `null`，单通道是对的，但双通道就错了。

**所以要做的**：`pppIo()` 实现为：若 `self.data_io != null` 则返回该 Io，否则返回 `null`。不引入 CMUX 或拨号逻辑，只做「有 data_io 就暴露、没有就 null」。

---

**1.4 暴露 mode()（可选）— 为什么要做**

plan 的烧录验证里要求打日志：`Modem mode: single_channel`。若 Modem 内部不暴露“当前是单通道还是双通道”，固件和测试就只能通过「是否传了 data_io」间接推断，日志也不直观。

**所以要做的**：增加 `pub fn mode(self: *const Self) enum { single_channel, multi_channel }`，按 `data_io != null` 判定。这样 UT 可以直接断言 `mode() == .multi_channel`，固件可以统一打 `mode=single_channel`，和 plan 的通过标准一致。

---

### 阶段 2 详解：单元测试（MD-xx）

**背景：plan 的 Step 8 Mock 用例**

plan 为 Step 8 列了一组 Mock 用例（MD-01～07、MD-12，不含 CMUX 的 MD-08～11），用来在**无硬件**的情况下证明：  
「单通道时 AT 走唯一 Io」「双通道时 AT 只走 at_io、PPP 只走 data_io」「无效配置会报错」「multi 下 enterCmux 不破坏行为」。  
这些用例是 Step 8 的**契约**：实现要对齐它们，以后改 modem 代码时也要保证这些测试继续过。

---

**各用例在防什么、为什么要测**

- **MD-03 invalid init**：防止“没给任何 Io 却 init 成功”，见 1.1。  
- **MD-01 single-ch init**：保证“只给一个 io 时”能正常建 Modem，且行为是单通道（例如 at() 的字节都在这条 io 上）。  
- **MD-02 / MD-07**：双通道建好后，`mode() == .multi_channel` 且 `pppIo() != null`，否则上层拿不到 PPP 通道。  
- **MD-06 multi-ch PPP**：**关键**：证明 PPP 数据**只**从 `pppIo()` 出去、且只出现在 data_io 的 mock 里，at_io 上不应出现这些字节。否则就说明路由错了（例如误把 PPP 写到 AT 口）。  
- **MD-04 / MD-05**：单通道 AT 走唯一 io、双通道 AT 只走 at_io；现有测试已覆盖，可加注释对应到 MD-04/MD-05。  
- **MD-12**：双通道下不应使用 CMUX；`enterCmux()` 在 multi 下应为 no-op（调用不崩溃、不改变 pppIo）。避免以后有人误在双通道路径里走 CMUX。

**MD-13（enterDataMode）为什么 Step 8 不实现**

plan 里 MD-13 写的是「ATD*99# → CONNECT → pppIo 激活」。  
在 **multi-channel** 下，数据口本来就有，Step 8 只需求「pppIo() 可用」，这已由 MD-07/MD-06 覆盖。  
在 **single-channel** 下，「pppIo 激活」需要先建 CMUX、再拨号，属于 Step 9/10。  
所以 Step 8 不实现 `enterDataMode()` API，也不发 ATD*99#，只保证 multi 下 `pppIo()` 返回 data_io 即可。

---

### 阶段 3 详解：固件 Step 8 段落与 quectel_stub

**背景：为什么要有“Step 8 专用”的固件块**

plan 要求 Step 8 除 Mock 外，还要有一次**烧录验证**：在真机上用**占位 Module（quectel_stub）**和 **gpio=null** 创建 Modem，确认：  
- init 成功、mode 为 single_channel；  
- `modem.at().send("AT")` 返回 ok（证明 AT 路由到了真实 UART）；  
- `modem.pppIo() == null`（CMUX 未开，符合预期）。

目前 110-cellular 里已经有 Step4/Step5 等用 Modem 发 AT 的流程，但那是用**完整 quectel profile** 和实际 Cellular 状态机跑的，没有单独一块「只验证 Modem 路由」的、可打 Step 8 标准日志的代码。  
若不加这段，就无法在文档/验收上说“Step 8 烧录已按 plan 做过”。

**所以要做的**：在 `app.zig` 里加一个与 step0/step4/step5 并列的 **Step 8 块**，**在 step3 之后、`runCellularFsm` / `runCellularFsmMock` 之前**执行（使用同一 `io` / 同一 MockIo），即顺序：step0 → step2 → step3 → **Step 8** → step4/step5。  
- 用 **quectel_stub**（不是完整 quectel）和 **gpio=null** 调用 `Modem.init(.{ .io = uart_io, .time = ..., .gpio = null })`；  
- 打 plan 里约定的日志：`=== Step 8: Modem routing test ===`、`Modem mode: single_channel`、`modem.at().send(...) -> status=ok`、`modem.pppIo() = null (CMUX not active yet, expected)`。  
- **AT 探测**：quectel_stub 的 `commands` 未导出 `Probe`，固件 Step 8 请用 `modem.at().sendRaw("AT\r\n", timeout)` 做探测；若日后 stub 导出 `Probe` 再改用 `send(Module.commands.Probe, {})`。  
这样真机烧录一次，串口输出就能和 plan 的通过标准逐条对应。

**为什么用 quectel_stub**

Step 8 的验收点是**路由**（AT 是否打到对的 Io、pppIo 是否在单通道下为 null），不是完整模组能力。用 stub 可以：  
- 减少对完整 profile（ATI、CEREG 等）的依赖；  
- 和 plan 的“Step 8 使用占位 Module，Step 12 再用完整 quectel”一致。  
Mock 板型上在 **`runCellularFsmMock` 内部、现有 bootstrap 逻辑之前**，用**同一 MockIo** 先跑 Step 8（quectel_stub + Modem.init → 检查 mode、at().sendRaw、pppIo() == null），再跑现有 Step4 mock，可以保证 `zig build test-110-cellular-firmware` 一次覆盖 Step 8 + Step4 且在无硬件时通过。

---

### 阶段 4 详解：调用方适配与文档

**4.1 为什么所有 Modem.init 都要 try**

一旦 1.1 把 `init` 改成 `InitError!Self`，**所有**调用 `Modem.init(...)` 的地方都会变成“可能失败”。Zig 里必须显式处理错误，否则无法编译。  
注意：**cellular.zig 不调用 Modem.init**（`Cellular.init(modem, injector)` 接收的是已建好的 Modem）。需要改的是：  
- **test/firmware/110-cellular/app.zig**：`runCellularFsm` 里一处、`runCellularFsmMock` 里一处；  
- **test/unit/pkg/cellular/modem/modem_test.zig**：所有使用 `ModemUnderTest().init(...)` 的用例。  
在上述位置改为 `var m = try Modem.init(...)` 或 `Modem.init(...) catch |e| { ... }`，并根据需求处理 `NoIo`（例如返回错误、打日志、或 panic）。  
这样“无效配置”的报错才能从 Modem 层传到上层，而不是在 init 里被吞掉。

**4.2 文档**

**根目录** `cellular_dev.html` 的「开发进度」是给人和后续开发看的单一事实来源。Step 8 做完并验收后，应在「已完成」里加一条 Step 8，并写上：无效 init 报错、multi 下 pppIo、MD 用例、Step 8 烧录段落均已补齐。这样以后查“Step 8 到底做没做、做了啥”不用再翻代码和 plan 对表。

---

### 阶段 3：quectel_stub 与固件

| # | 任务 | 说明 | 涉及文件 |
|---|------|------|----------|
| 3.1 | **固件 Step 8 段落** | 在 `test/firmware/110-cellular/app.zig` 中增加 Step 8 专用块，**在 step3 之后、`runCellularFsm` 之前**执行（与 step0/step4/step5 并列）：用 **quectel_stub** + **gpio=null** 实例化 Modem（`.io = uart_io`，single-channel）；打日志 `[step8]` 或 `=== Step 8: Modem routing test ===`、`Modem mode: single_channel`；用 **`modem.at().sendRaw("AT\r\n", timeout)`** 做 AT 探测（quectel_stub 未导出 Probe）并打 status；`modem.pppIo() == null` 打日志「CMUX not active yet, expected」。 | `test/firmware/110-cellular/app.zig` |
| 3.2 | **Mock 板型 Step 8** | 在 **`runCellularFsmMock` 开头**、现有 Step4 bootstrap 之前，用同一 MockIo + quectel_stub 先跑 Step 8 验证（mode、sendRaw、pppIo()==null），再跑 Step4，保证 `zig build test-110-cellular-firmware` 通过。 | 同上 |

**验收**：真机烧录能看到 Step 8 日志且 `modem.at()` 返回 ok、`pppIo() == null`；mock 构建与测试通过。

---

### 阶段 4：调用方适配与文档

| # | 任务 | 说明 | 涉及文件 |
|---|------|------|----------|
| 4.1 | **所有 Modem.init 调用方** | 所有 `Modem.init(...)` 改为 `try Modem.init(...)` 或 `Modem.init(...) catch |e| ...`，并处理 `InitError`。**调用方仅两处**：`test/firmware/110-cellular/app.zig`（`runCellularFsm`、`runCellularFsmMock` 各一处）与 `test/unit/pkg/cellular/modem/modem_test.zig`（所有 init 用例）。cellular.zig 不调用 Modem.init，无需改。 | `test/firmware/110-cellular/app.zig`、`test/unit/pkg/cellular/modem/modem_test.zig` |
| 4.2 | **文档更新** | **根目录** `cellular_dev.html` 开发进度：在「已完成」中增加 Step 8 条目（在阶段 1～3 验收通过后）；注明：无效 init 报错、multi 下 pppIo、MD 用例与 Step 8 烧录段落已补齐。最后更新日期调整。 | 根目录 `cellular_dev.html` |

---

## 三、建议执行顺序

1. **1.1 + 1.2 + 1.3 + 1.4** → 编译；改 **4.1**（Cellular 等 try init）。
2. **2.1～2.8** → 补齐/调整 `modem_test.zig`，全部通过。
3. **3.1 + 3.2** → 固件 Step 8 块 + mock 路径。
4. 真机烧录验证 Step 8 日志与行为。
5. **4.2** → 文档标记 Step 8 完成。

---

## 四、通过标准（汇总）

- [ ] 无效 init（无 io 且无 at_io）返回错误，无静默 stub。
- [ ] multi-channel 时 `pppIo()` 返回 `data_io`；单通道时 `pppIo() == null`。
- [ ] UT：MD-01～07、MD-12 有对应用例且通过。
- [ ] 固件有 Step 8 专用日志；真机烧录：mode=single_channel、at() ok、pppIo()=null。
- [ ] `zig build test-cellular` 与 `zig build test-110-cellular-firmware` 通过。
- [ ] 文档 Step 8 标记完成（可选，在验收后）。

---

如无异议，可按此计划开始开发；若有步骤想合并/延后/拆分，可指出具体编号再调。
