# Step 10 可操作计划：modem.zig 完整 — Modem CMUX 全链路

**目标（plan.md）：** 补全 Modem 的 CMUX 管理逻辑，在真机上验证完整的单通道模式全链路。  
**里程碑 #3：** Modem 硬件驱动在 ESP32S3 + 真实 4G 模组上全链路跑通。

---

## 一、当前实现状态（已具备）

| 项目 | 状态 | 说明 |
|------|------|------|
| `Modem.enterCmux()` | ✅ 已有 | 单通道：AT+CMUX=0 + SABM/UA + Io 切换，返回 `EnterCmuxResult` |
| `Modem.exitCmux()` | ✅ 已有 | 单通道：stopPump(可选) + delay + DISC + 恢复 raw Io |
| `Modem.isCmuxActive()` | ✅ 已有 | 返回 `cmux != null and cmux.active` |
| `Modem.pppIo()` | ✅ 已有 | CMUX 激活且 config 含 `.ppp` 时返回 PPP 通道 Io；默认 config 仅 AT，故当前 pppIo() 为 null |
| CMUX 双模式 pump | ✅ 已有 | use_main_thread_pump / 静态任务，Basic & Advanced 帧 |
| 单测 MD-08～MD-11 | ✅ 已有 | single-ch enterCmux、CMUX AT、pppIo 为 null（AT only）、exitCmux |
| 110-cellular 真机流程 | ✅ 已有 | step0→波特率→enterCmux→step4/step5→exitCmux，无结构化 8 Phase 日志 |

---

## 二、Step 10 仍需完成的内容（可操作清单）

### 2.1 Modem API 补全（plan 明确要求）

| # | 任务 | 说明 | 验收 |
|---|------|------|------|
| 1 | **实现 `Modem.enterDataMode() !void`** | 发送 `ATD*99#`（或 profile 指定拨号串），读响应直至 `CONNECT` 或超时；成功后 PPP 通道可用于数据。可依赖现有 `at_engine.sendRaw()`，解析 CONNECT。 | 单测或烧录：调用后 pppIo() 可写且无 AT 响应混入（或按当前设计仅“进入数据模式”状态，由上层 PPP 用 pppIo()） |
| 2 | **实现 `Modem.exitDataMode() void`** | 发送 `+++`（转义序列，与模组约定 guard time），再发 `ATH` 挂断，使模组回到 AT 命令模式。 | 单测或烧录：exitDataMode 后 at().sendRaw("AT") 得 OK |

**涉及文件：** `src/pkg/cellular/modem/modem.zig`  
**可选：** 拨号串/guard time 放在 `profiles/quectel.zig`（或 Module）的配置中，Modem 只调 at_engine 发字节。

---

### 2.2 烧录验证：8 Phase 结构化 + 通过标准

plan 要求的 8 Phase 与最终 log 如下，需在 110-cellular 中**显式跑一遍**并打 log（可与现有 step0～step5 流程并存，用编译开关或单独入口均可）：

| Phase | 内容 | 当前对应 | 待做 |
|-------|------|----------|------|
| 1 | 初始化：`Modem.init(...)`，log `mode=single_channel` | 已有 init | 在“Step 10 流程”里打 `[I] Modem initialized: mode=single_channel`（或等价） |
| 2 | 直连 AT（CMUX 前）：`modem.at().send("AT", 5000)`，log `Direct AT -> status=ok` | 已有 step 中 AT | 在 Step 10 专用段落里发 AT 并打上述 log |
| 3 | SIM + 信号：通过 `modem.at()` 查 SIM/信号，log `SIM: ready`、`Signal: rssi=..., reg=...` | step4/step5 已有 | 在 Step 10 段落里调用 getSimStatus/getSignal 并打 plan 约定 log |
| 4 | 进入 CMUX：`modem.enterCmux()`，log `CMUX negotiated, channels open`、`modem.isCmuxActive() = true` | 已有 enterCmux | 打上述两条 log |
| 5 | CMUX AT 通道验证：`modem.at().send("AT+CSQ", 5000)`，log `CMUX AT channel -> +CSQ: ...` | step4 已走 CMUX AT | 在 Step 10 里显式发 AT+CSQ 并打 log |
| 6 | PPP 通道就绪：`modem.pppIo()`，log `PPP Io available: true/false` | 当前 config 仅 AT，pppIo() 为 null | **二选一**：① 增加“双通道”config（如 DLCI1=AT, DLCI2=PPP），enterCmux 后 pppIo() 非 null，打 `true`；② 或保持单 AT 配置，打 `false` 并注明“当前仅 AT 通道” |
| 7 | 退出 CMUX：`modem.exitCmux()`，log `CMUX closed, modem.isCmuxActive() = false` | 已有 exitCmux | 打上述 log |
| 8 | 恢复直连 AT：`modem.at().send("AT", 5000)`，log `Post-CMUX direct AT -> status=ok` | 未做 | **新增**：exitCmux 后发一次 AT，打该 log |

**通过标准（plan）：**

- 8 个 Phase 全部成功执行，无崩溃  
- 直连 AT → CMUX AT → 退出 CMUX → 直连 AT 全链路通畅  
- （若启用双通道）PPP Io 在 CMUX 激活后可用  
- 串口最终输出 **`MODEM DRIVER TEST PASSED`**

**涉及文件：** `test/firmware/110-cellular/app.zig`（新增一段“Step 10: Modem driver integration test”或通过开关切到 8 Phase 流程）。

---

### 2.3 双通道配置（可选，用于 Phase 6 “PPP Io available: true”）

- **现状：** `ModemConfig.cmux_channels` 默认只有 `.{ .dlci = 1, .role = .at }`，故 `pppIo()` 在 CMUX 下也为 null。  
- **可选：** 在 110-cellular 或 board 配置中增加一种 config，例如 `.{ .dlci = 1, .role = .at }, .{ .dlci = 2, .role = .ppp }`，enterCmux 时打开两路 DLCI，Phase 6 检查 `modem.pppIo() != null` 并打 `PPP Io available: true`。  
- **注意：** 部分模组 DLCI 顺序或拨号方式不同，若只做“全链路 + 单 AT 通道”验收，Phase 6 可先打 `false` 并注明，不阻塞 Step 10 通过。

---

### 2.4 Mock 测试（4 个，plan 要求）

| ID | 验证内容 | 当前状态 |
|----|----------|----------|
| MD-08 | single-ch enterCmux：AT+CMUX=0 发出，SABM/UA，Io 切换 | ✅ 已有 |
| MD-09 | single-ch CMUX AT：enterCmux 后 at().send 走 CMUX 通道 | ✅ 已有 |
| MD-10 | single-ch CMUX PPP：当前为“仅 AT 时 pppIo 为 null” | ✅ 已有 |
| MD-11 | single-ch exitCmux：DISC，AT 恢复 raw Io，isCmuxActive false | ✅ 已有 |

- **待做：** 若实现 `enterDataMode`/`exitDataMode`，可补 **MD-13**（或等价）：enterDataMode 后 pppIo 可用 / exitDataMode 后 AT 恢复正常（见 plan Step 8 表）；非 plan Step 10 强制 4 个之内，属增强。

---

## 三、建议执行顺序（可操作）

1. **实现 enterDataMode / exitDataMode**（§2.1）  
   - 在 `modem.zig` 增加 `enterDataMode() !void`、`exitDataMode() void`。  
   - 拨号串用 `ATD*99#\r\n`（或从 Module 读），CONNECT 判定用 at_engine 读到的字符串；exit 用 `+++\r\n` + 适当延时 + `ATH\r\n`。

2. **110-cellular 增加“Step 10 集成段落”**（§2.2）  
   - 按 Phase 1～8 顺序调用现有 Modem API，并打 plan 约定 log。  
   - Phase 8：exitCmux 后补一次 `modem.at().sendRaw("AT\r\n", 5000)`，打 `Post-CMUX direct AT -> status=ok`。  
   - 最后打 `MODEM DRIVER TEST PASSED`。

3. **（可选）双通道 config**（§2.3）  
   - 需要“PPP Io available: true”时再加；否则 Phase 6 打 `false` 并注释。

4. **（可选）补 MD-13 或 enterDataMode/exitDataMode 单测**（§2.4）  
   - 用 MockIo feed CONNECT / OK，验证 enterDataMode 成功；feed OK 验证 exitDataMode 后 AT 正常。

---

## 四、完成标准汇总

- [ ] `Modem.enterDataMode()`、`Modem.exitDataMode()` 已实现并在 modem 层可测/可烧录验证。  
- [ ] 110-cellular 存在“Step 10”的 8 Phase 流程，日志与 plan 一致，结尾有 `MODEM DRIVER TEST PASSED`。  
- [ ] Phase 8（exitCmux 后直连 AT）通过。  
- [ ] （可选）双通道 config 下 Phase 6 为 `PPP Io available: true`。  
- [ ] MD-08～MD-11 保持通过；若有 enterDataMode/exitDataMode，则增加对应单测并通过。
