# Step 10 Modem CMUX 全链路 开发计划

**状态：待开始**

> 目标：补全 Modem 的 CMUX 管理逻辑（enterCmux/exitCmux、config.cmux_channels、Io 切换），在单通道模式下由 Modem 发 AT+CMUX=0 并完成 SABM/UA，使 at() 与 pppIo() 走 CMUX 虚拟通道；真机烧录验证全链路（里程碑 #3）。

---

## 一、范围与前置

- **本计划覆盖**：`Modem.enterCmux()` / `exitCmux()` 实现（AT+CMUX=0 → Cmux.open → at_engine.setIo / pppIo 绑定）、`isCmuxActive()`、`config.cmux_channels` 校验与 DLCI 绑定（R41）、startPump/stopPump 与 close、MD-08～MD-11 单测、110-cellular Step 10 烧录验证段落。可选本步内实现 `enterDataMode()` / `exitDataMode()`（ATD*99# / +++）或留后续。
- **前置**：Step 9 已完成（cmux.zig、MX-01～MX-10、open/close/channelIo/pump）。调用方发 AT+CMUX=0 后 Cmux.open(dlcis) 的约定在 Step 10 中由 Modem 履行。

---

## 二、任务列表（建议顺序）

### 阶段 1：Modem 侧 CMUX 状态与配置

| # | 任务 | 说明 | 涉及文件 |
|---|------|------|----------|
| 1.1 | **isCmuxActive** | `Modem.isCmuxActive() bool`，返回当前是否处于 CMUX 模式（有 Cmux 实例且 active）。 | `src/pkg/cellular/modem/modem.zig` |
| 1.2 | **config.cmux_channels 校验** | 单通道下 init 或 enterCmux 前校验 `config.cmux_channels` 存在且包含 at_dlci、ppp_dlci（R41）；无效配置返回明确错误。 | `modem.zig`、`types.zig`（若需扩展 CmuxChannelConfig） |

### 阶段 2：enterCmux / exitCmux 实现

| # | 任务 | 说明 | 涉及文件 |
|---|------|------|----------|
| 2.1 | **enterCmux()** | 单通道五步：1）用当前 at_engine 的 Io 发 `AT+CMUX=0` 并等 OK；2）`Cmux(Thread, Notify, max_channels).init(io, notifiers)`；3）`cmux.open(dlcis)`（dlcis 来自 config.cmux_channels）；4）`at_engine.setIo(cmux.channelIo(at_dlci))`；5）`startPump()`（或等效）。多通道 / 无 config 时 no-op 或返回错误。 | `modem.zig` |
| 2.2 | **exitCmux()** | 单通道：1）stopPump；2）`cmux.close()`；3）`at_engine.setIo(原始 raw Io)`；4）清空 CMUX 状态（isCmuxActive() == false）。 | `modem.zig` |
| 2.3 | **pppIo() 绑定** | 单通道且 isCmuxActive() 时，`pppIo()` 返回 `cmux.channelIo(ppp_dlci)`；否则仍为 null（与 Step 8 一致）。 | `modem.zig` |

### 阶段 3：单测 MD-08～MD-11

| # | 任务 | 说明 | 涉及文件 |
|---|------|------|----------|
| 3.1 | **MD-08** | single-ch enterCmux：Mock 下 AT+CMUX=0 发出、feed OK；feed 各 DLCI 的 UA；断言 at_engine 的 Io 切换为 CMUX channel、isCmuxActive() == true。 | `test/unit/pkg/cellular/modem/modem_test.zig`（或对应 UT 文件） |
| 3.2 | **MD-09** | single-ch CMUX AT：enterCmux 后 at().send("AT") → 请求走 CMUX DLCI 2（或 config 的 at_dlci），Mock 可 feed 响应，断言 ok。 | 同上 |
| 3.3 | **MD-10** | single-ch CMUX PPP：enterCmux 后 pppIo() 非 null，且为 cmux.channelIo(ppp_dlci)。 | 同上 |
| 3.4 | **MD-11** | single-ch exitCmux：exitCmux() 后 DISC 发出（Mock 可校验 sent），at_engine 恢复 raw Io，isCmuxActive() == false，pppIo() == null。 | 同上 |

### 阶段 4：固件 Step 10 烧录验证

| # | 任务 | 说明 | 涉及文件 |
|---|------|------|----------|
| 4.1 | **Step 10 烧录块** | 在 110-cellular app.zig 中增加 Step 10 段落（可与 Step 9 块并列或替代）：Phase 1～8 按 plan.md § Step 10（初始化 → 直连 AT → SIM/信号 → enterCmux → CMUX AT → pppIo 可用 → exitCmux → 直连 AT 恢复），打 `[step10]` 与约定日志。 | `test/firmware/110-cellular/app.zig` |
| 4.2 | **Mock 路径 Step 10** | runCellularFsmMock 或等效路径中执行 Step 10 逻辑（feed AT+CMUX=0 OK、UA、AT 响应等），保证 `zig build test-110-cellular-firmware`（若存在）通过。 | 同上 |

### 阶段 5：可选 — enterDataMode / exitDataMode

| # | 任务 | 说明 | 涉及文件 |
|---|------|------|----------|
| 5.1 | **enterDataMode** | 单通道下通过 CMUX AT 通道发 ATD*99#，等 CONNECT；可本步实现或标 TODO 留 Step 11。 | `modem.zig` |
| 5.2 | **exitDataMode** | +++ 或 ATH 退出数据模式；可本步实现或标 TODO。 | `modem.zig` |

---

## 三、通过标准（汇总）

- [ ] `Modem.enterCmux()` / `exitCmux()` / `isCmuxActive()` 实现；单通道下 AT+CMUX=0 → Cmux.open → at_engine.setIo(channelIo(at_dlci))，pppIo() 返回 channelIo(ppp_dlci)。
- [ ] `config.cmux_channels` 校验与 DLCI 绑定（R41）。
- [ ] MD-08～MD-11 单测通过。
- [ ] 固件 Step 10 烧录：8 Phase 全链路通畅，串口输出 "MODEM DRIVER TEST PASSED"（或等价）。
- [ ] `zig build test-cellular` 与（若适用）固件 mock 测试通过。

---

## 四、与 plan.md 的对应

- plan.md § Step 10：modem.zig 完整 — Modem CMUX 全链路（里程碑 #3）。
- 烧录验证逻辑与 Phase 1～8 以 plan.md 为准；本计划仅拆分为可执行任务与单测项。

---

## 五、参考

- Step 9：`docs/cellular_step9_dev_plan.md`（Cmux 由调用方发 AT+CMUX=0 后 open；Step 10 中由 Modem 发）。
- plan.md § Step 10、§ Q9、R41（cmux_channels）。
- `src/pkg/cellular/modem/modem.zig`：当前 enterCmux/exitCmux 占位实现。
