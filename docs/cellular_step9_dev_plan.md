# Step 9 CMUX 开发计划（可操作）

**状态：已完成（2026-03-19）**

> 目标：按 plan.md Step 9 实现 GSM 07.10 CMUX 帧编解码与虚拟通道，在真机上完成 CMUX 协商与虚拟通道通信（核心里程碑 #2）。

---

## 一、范围与不做的边界

- **本计划覆盖**：`at/cmux.zig` 的帧编解码（Frame、encodeFrame、decodeFrame、calcFcs）、Cmux 会话（init、open、close、channelIo、pump、startPump/stopPump）、MX-01～MX-10 单测、固件 Step 9 烧录验证段落。**不包含** Modem.enterCmux()/exitCmux() 与 Modem 侧 Io 切换（留 Step 10）。
- **本计划不覆盖**：Step 10 Modem CMUX 全链路（enterCmux 内调 Cmux、at_engine.setIo、pppIo 绑定）；enterDataMode/ATD*99#（Step 10）；R41 的 ModemConfig.cmux_channels 校验与 enterCmux 使用 config（Step 10）。Step 9 的 Cmux 可先接受「调用方发 AT+CMUX=0 后再 open(dlcis)」的约定，与 plan § Q9 一致。

---

## 二、任务列表（按推荐执行顺序）

### 阶段 1：cmux.zig 帧与类型

| # | 任务 | 说明 | 涉及文件 |
|---|------|------|----------|
| 1.1 | **Frame 结构体** | 定义 `Frame`：`dlci: u8`、`control: u8`（SABM/UA/DM/UI 等）、`data: []const u8`（UI 帧 payload；SABM/UA 可为空）。与 plan §5.6 一致。 | `src/pkg/cellular/at/cmux.zig` |
| 1.2 | **calcFcs** | 实现 `calcFcs(data: []const u8) u8`，按 GSM 07.10 的 FCS 算法（通常为 8-bit 与 0x7E 的 XOR 链）。需至少 1 个已知测试向量用例（MX-08）。 | `src/pkg/cellular/at/cmux.zig` |
| 1.3 | **encodeFrame** | `encodeFrame(frame: Frame, out: []u8) usize`：生成 0x7E 起止、address/control/length/FCS、中间 0x7D 转义。返回写入字节数；若 out 不足则返回 0 或错误。 | `src/pkg/cellular/at/cmux.zig` |
| 1.4 | **decodeFrame** | `decodeFrame(data: []const u8) ?Frame`：从 0x7E 起解析，去转义，校验 FCS，解析出 dlci/control/data；失败返回 null。 | `src/pkg/cellular/at/cmux.zig` |

**验收**：编译通过；MX-01（encode）、MX-02（decode）、MX-08（FCS）可写单测并过。

---

### 阶段 2：Cmux 会话与虚拟通道

| # | 任务 | 说明 | 涉及文件 |
|---|------|------|----------|
| 2.1 | **Cmux 泛型与 init** | `Cmux(comptime Thread, comptime Notify, comptime max_channels)`，`init(io: Io) Self` 绑定底层 Io；内部持 `channels`（每 DLCI 的环形缓冲或线性缓冲 + Notify）。plan §5.6：channelIo 的 pollFn 用 Notify.timedWait。 | `src/pkg/cellular/at/cmux.zig` |
| 2.2 | **open(dlcis)** | `open(self: *Self, dlcis: []const u8) !void`：**不**发 AT+CMUX=0（caller 已发）。对每个 dlci 发 SABM，读到底层 Io 上的 UA 后该 DLCI 为 open；超时或收到 DM 返回错误。若定义错误集（如 `OpenError`），建议在 **cmux.zig 的 Cmux 结构体或模块内** 定义。 | `src/pkg/cellular/at/cmux.zig` |
| 2.3 | **channelIo(dlci)** | 返回该 DLCI 的虚拟 Io：read 从该 DLCI 的 channel buffer 取；write 编码为 UIH 帧写底层 io；pollFn 用 `Notify.timedWait(timeout)`，pump 解到该 DLCI 时 signal。 | `src/pkg/cellular/at/cmux.zig` |
| 2.4 | **pump** | `pump(self: *Self) void`：从底层 io 读（非阻塞或短超时），按 0x7E 切帧，decodeFrame，将 payload 写入对应 DLCI 的 buffer 并 signal 该 channel 的 Notify。 | `src/pkg/cellular/at/cmux.zig` |
| 2.5 | **startPump / stopPump** | `startPump(self: *Self) !void` 用 Thread  spawn 循环：poll(10ms) 或 sleepMs(10) 后 pump()。`stopPump(self: *Self) void` 设标志并 join 线程。 | `src/pkg/cellular/at/cmux.zig` |
| 2.6 | **close** | `close(self: *Self) void`：对已 open 的 DLCI 发 DISC，可等 UA/DM 或超时后忽略；清空 channel 状态；pump 若在运行由 stopPump 负责。 | `src/pkg/cellular/at/cmux.zig` |

**验收**：MX-03（SABM/UA）、MX-04（channel write → UIH）、MX-05（喂 UIH → channel read）、MX-06（隔离）、MX-07（DISC）、MX-09（并发）、MX-10（pump demux）可写单测并过。

---

### 阶段 3：单元测试（MX-01～MX-10）

| # | 测试 ID | 验证内容 | 说明 |
|---|---------|----------|------|
| 3.1 | MX-01 | UIH encode | 给定 dlci + data，encodeFrame 得到以 0x7E 开头/结尾、含正确 address/control/length/FCS 及 0x7D 转义的字节序列。 |
| 3.2 | MX-02 | UIH decode | 喂入合法 UIH 字节（可来自 MX-01 或手写），decodeFrame 返回 Frame { dlci, control, data } 且 data 与输入一致。 |
| 3.3 | MX-03 | SABM/UA handshake | MockIo 喂 open 所需 UA 序列；open(dlcis) 后 SABM 从底层 io 发出，握手成功。 |
| 3.4 | MX-04 | channel write | channelIo(2).write("AT") 后，底层 MockIo 收到 DLCI=2 的 UIH 帧。 |
| 3.5 | MX-05 | channel read | 向 MockIo 写入 DLCI=2 的 UIH 帧，pump 一次（或由 pump 线程处理）后 channelIo(2).read() 得到 payload。 |
| 3.6 | MX-06 | channel isolation | DLCI 1 的 UIH 帧经 pump 后仅 DLCI 1 的 channel 可读到，DLCI 2 读不到。 |
| 3.7 | MX-07 | DISC/close | close() 后底层收到各 DLCI 的 DISC 帧。 |
| 3.8 | MX-08 | FCS | 使用已知 GSM 07.10 测试向量（或从标准/开源实现取一段）验证 calcFcs 与 decode 校验一致。 |
| 3.9 | MX-09 | concurrent | 交错喂 DLCI 1 与 DLCI 2 的 UIH 帧，两路 read 分别得到正确数据。 |
| 3.10 | MX-10 | pump demux | 混合多帧经 pump 后正确写入各 DLCI buffer，对应 channel read 可取出。 |

**验收**：仓库根目录执行 `zig build test-cellular`（含 cmux 用例）全过。若只跑 cmux 子集：`cd test/unit && zig build test -- --test-filter "cmux"`。

---

### 阶段 4：固件 Step 9 段落

| # | 任务 | 说明 | 涉及文件 |
|---|------|------|----------|
| 4.1 | **Step 9 烧录块** | 在 `test/firmware/110-cellular/app.zig` 中，在 **Step 8 块（runStep8ModemRouting）之后、runCellularFsm 调用之前** 增加 Step 9 块（即顺序：step3 → runStep8ModemRouting → **Step 9** → runCellularFsm）：1）直连 AT 确认就绪；2）发 AT+CMUX=0，等 OK；3）`Cmux(Thread, Notify, 4).init(uart_io)`，`open(&.{ 1, 2 })`（或与模组一致的 DLCI）；4）channelIo(2).write("AT\r\n") + pump + read，打日志；5）channelIo(2).write("AT+CSQ\r\n") + pump + read，打日志；6）close()；7）直连 AT 再发 AT 验证恢复。打 `[step9]` 与 plan 约定日志。 | `test/firmware/110-cellular/app.zig` |
| 4.2 | **Mock 路径 Step 9** | 在 **runCellularFsmMock 内、Step 8 验证之后、Step4 bootstrap（ModemT/CellularT 与 cell.powerOn）之前** 执行 Step 9 逻辑：用同一 MockIo，按需 feed UA/UIH 等模拟模组响应，保证 `zig build test-110-cellular-firmware` 仍过。 | 同上 |

**验收**：真机烧录见 Step 9 日志；AT+CMUX=0 成功；SABM/UA 成功；虚拟通道 AT/AT+CSQ 有响应；close 后直连 AT 正常。

---

### 阶段 5：文档与兼容

| # | 任务 | 说明 | 涉及文件 |
|---|------|------|----------|
| 5.1 | **替换占位 CmuxSession** | 当前 `cmux.zig` 为 CmuxSession(IoType, Notify) 占位。执行前用 `grep -r CmuxSession\|openChannel` 查引用（目前仅 cmux.zig 内定义、mod.zig 导出模块）。若他处引用，改为 Cmux(Thread, Notify, max_channels) 或保留类型别名指向 Cmux，避免破坏调用方。 | `src/pkg/cellular/at/cmux.zig`、若有引用则含引用处 |
| 5.2 | **文档更新** | **根目录** `cellular_dev.html`：Step 9 完成后在「开发进度」中增加 Step 9 条目；最后更新日期调整。 | 根目录 `cellular_dev.html` |

---

## 二（续）各阶段详细说明与背景

下面按阶段说明：**具体要改什么**、**在整体设计里处于什么位置**、**为什么要这么做**。

---

### 背景：为什么需要 CMUX、Step 9 的边界

单通道（一根 UART）时，AT 指令和 PPP 数据**共用同一条物理链路**。GSM 07.10（3GPP TS 27.010）规定在这条链路上用**多路复用帧**区分逻辑通道：每个逻辑通道由一个 DLCI（0～63）标识，常见约定是 DLCI 0 信令、DLCI 1 数据（PPP）、DLCI 2 为 AT。模组在收到 **AT+CMUX=0** 后进入多路复用模式，之后线路上只传输 0x7E 起止的帧，不再传裸 AT 文本。

**Step 9 的职责**：实现「帧的编解码」和「虚拟通道的读写与 pump」，使上层可以：  
- 发 AT+CMUX=0（仍用现有 AtEngine 通过当前 Io）；  
- 调用 `Cmux.open(dlcis)` 做 SABM/UA 握手；  
- 用 `channelIo(dlci)` 拿到虚拟 Io，在虚拟通道上发 AT 或 PPP 数据；  
- 通过 `pump()`（或 pump 线程）把底层读到的字节解帧并分发到各 DLCI。  

**不放在 Step 9 的**：Modem 在单通道下何时调 enterCmux、如何用 config.cmux_channels 绑定 at/ppp、at_engine.setIo 与 pppIo() 的切换，留到 **Step 10**。这样 Step 9 只交付「可用的 Cmux 类型 + 单测 + 固件里直接拿 Cmux 做一次协商与虚拟通道收发」的闭环。

---

### 阶段 1 详解：帧格式与编解码

**GSM 07.10 帧结构（简要）**  
- 帧界：**0x7E**（flag）。  
- **Address**：1 或 2 字节，含 DLCI 与 EA 位；常用 1 字节时 DLCI 在低 6 位。  
- **Control**：1 或 2 字节，区分 SABM(0x2F)、UA(0x63)、DM(0x0F)、DISC、UI(0x03) 等。  
- **Length**：0/1/2 字节（取决于协商），UI 帧为信息长度。  
- **Info**：仅 UI 等帧有；需 **0x7D 转义**（0x7E→0x7D 0x5E，0x7D→0x7D 0x5D）。  
- **FCS**：1 字节，对 address+control+length+info 计算；算法见标准，校验失败则丢帧。  
- 结束：**0x7E**。

**1.1 Frame 结构体**  
plan §5.6 要求 `Frame` 含 `dlci`、`control`、`data`。解码后得到的是「哪个 DLCI、什么控制类型、payload 切片」；编码时据此生成字节流。不把「长度」单独暴露也可，由 data.len 推导。

**1.2 calcFcs**  
FCS 是接收校验与发送生成所共用。标准算法（8-bit XOR 链等）需与模组一致，否则真机校验失败。先实现标准算法，用 **MX-08** 单测与已知向量（可从开源实现或抓包取）锁定行为。

**1.3 encodeFrame**  
逻辑：按 address/control/length 写入，对 data 做 0x7D 转义，算 FCS 追加，首尾加 0x7E。若 `out.len` 不足可返回 0 或 error。这样 **MX-01** 可断言输出字节序列与预期一致。

**1.4 decodeFrame**  
逻辑：找 0x7E，取下一段到下一 0x7E，去转义，校验 FCS，解析 address/control/length 得到 dlci 与 payload。失败（格式错、FCS 错）返回 null，**MX-02** 验证 round-trip 与手写帧。

---

### 阶段 2 详解：会话与虚拟通道

**2.1 Cmux 与 init**  
Cmux 需要：底层 `io: Io`、每 DLCI 的缓冲区与一个 `Notify`（用于 pollFn 的 timedWait）。plan §5.6：`channelIo(dlci)` 返回的 Io 的 **pollFn 用 Notify.timedWait**，这样 AtEngine 或上层在 read 前可「等数据到达」而不忙等。init 只绑定 io，通道缓冲与 Notify 按 max_channels 分配。

**2.2 open(dlcis)**  
Q9 结论：**AT+CMUX=0 由调用方（或 Step 10 的 Modem）用 AtEngine 发送**，Cmux.open 只做 **SABM/UA 握手**。对每个 dlci 发送 SABM 帧，从底层 io 读直到收到该 DLCI 的 UA（或超时/收到 DM 则失败）。若为 open 定义错误集（如超时、收到 DM），建议在 **cmux.zig 的 Cmux 结构体或模块内** 定义，便于调用方 `try cmux.open(...)`。open 前底层必须已在 CMUX 模式，否则会读到裸 AT 文本导致解帧失败。

**2.3 channelIo(dlci)**  
每个 DLCI 对应一个「虚拟 Io」：  
- **write(buf)**：将 buf 封装为 UIH 帧（control=UI），encodeFrame 后写底层 io。  
- **read(buf)**：从该 DLCI 的 channel buffer 取数据（pump 解帧后写入），无数据可返回 WouldBlock。  
- **poll(timeout_ms)**：在该 DLCI 的 Notify 上 timedWait；pump 向该 DLCI 写入时 signal，poll 即被唤醒。  

这样 AtEngine 绑定 channelIo(at_dlci) 后，行为与直连 Io 一致，仅数据经 CMUX 封装。

**2.4 pump**  
从底层 io 非阻塞或短超时 read，按 0x7E 切出完整帧，decodeFrame，将 payload 写入对应 DLCI 的 buffer 并 **Notify.signal** 该 DLCI。若帧无效或 FCS 错则丢弃。pump 可由**独立线程**循环调用（startPump），或由调用方在合适时机单次调用（便于 Mock 单测）。

**2.5 startPump / stopPump**  
plan 与 R21：**CMUX pump 由独立线程驱动**，周期约 10ms（poll 或 sleepMs(10) 后 pump），避免物理 UART 积压。startPump 用 Thread.spawn 启动该循环；stopPump 设停止标志并 join。单测可不用线程，直接在主线程多次调 pump() 以配合 MockIo 喂数据（MX-05、MX-09、MX-10）。

**2.6 close**  
对每个已 open 的 DLCI 发 DISC，可选等 UA/DM 或超时；清空通道状态；若 pump 在跑则先 stopPump 再发 DISC（避免并发写底层 io）。这样模组与本地状态一致，便于 Step 9 烧录验证「close 后直连 AT 恢复」。

---

### 阶段 3 详解：单测在防什么

- **MX-01/MX-02**：编解码与标准/自洽一致，避免真机上帧格式错误。  
- **MX-08**：FCS 与标准或已知向量一致，避免模组校验失败。  
- **MX-03**：open 流程与 Mock 的 UA 序列匹配，避免握手逻辑错误。  
- **MX-04/MX-05**：虚拟通道读写与底层帧一一对应，避免 DLCI 或 payload 错位。  
- **MX-06**：通道隔离，避免 DLCI 1 数据被 DLCI 2 读到。  
- **MX-07**：close 发出 DISC，便于后续直连 AT 恢复。  
- **MX-09/MX-10**：交错与混合帧正确 demux，避免 pump 或 buffer 边界问题。

---

### 阶段 4 详解：固件 Step 9 段落

plan 要求 Step 9 除单测外有一次**烧录验证**：真机上发 AT+CMUX=0、open、经虚拟通道发 AT/AT+CSQ、close、再直连 AT。固件里加 **Step 9 专用块**，位置为 **Step 8 块（runStep8ModemRouting）之后、runCellularFsm 调用之前**，使用与 Step 8 相同的 uart_io，先直连 AT 确认就绪，再进入 CMUX 流程并打约定日志。这样验收时能逐条对「AT+CMUX=0 成功、SABM/UA 成功、虚拟通道有响应、close 后恢复」。

**Mock**：在 **runCellularFsmMock 内、Step 8 验证之后、Step4 bootstrap（ModemT/CellularT 与 cell.powerOn）之前** 执行 Step 9 逻辑，用同一 MockIo 按需 feed UA/UIH，保证无硬件时 `zig build test-110-cellular-firmware` 仍过。

---

### 阶段 5 详解：占位与文档

当前 `cmux.zig` 为 **CmuxSession(IoType, Notify)** 占位，返回 stub Io。Step 9 实现的是 **Cmux(Thread, Notify, max_channels)** 与完整 open/close/channelIo/pump。执行前可用 `grep -r CmuxSession\|openChannel` 查引用；当前仅 `src/pkg/cellular/at/cmux.zig` 内定义 CmuxSession，`src/mod.zig` 仅导出 cmux 模块。若他处引用 CmuxSession/openChannel，需改为使用 Cmux 或保留类型别名指向 Cmux，避免编译或行为不一致。

**文档**：Step 9 验收后在 **根目录** `cellular_dev.html` 的「开发进度」增加 Step 9 条目，注明帧编解码、open/close、channelIo、pump、MX-01～MX-10、Step 9 烧录段落已完成。

---

## 三、建议执行顺序

1. **1.1～1.4**：Frame、calcFcs、encodeFrame、decodeFrame → 编译 + MX-01、MX-02、MX-08。
2. **2.1～2.6**：Cmux 会话与 channelIo、pump、startPump/stopPump、close → MX-03～MX-07、MX-09、MX-10。
3. **4.1～4.2**：固件 Step 9 块 + 可选 mock 路径。
4. 真机烧录验证 Step 9 日志与行为。
5. **5.1～5.2**：替换/兼容 CmuxSession、更新文档。

---

## 四、通过标准（汇总）

- [x] Frame、calcFcs、encodeFrame、decodeFrame 实现完整；MX-01、MX-02、MX-08 通过。
- [x] Cmux(Thread, Notify, max_channels) init/open/close/channelIo/pump/startPump/stopPump 实现；MX-03～MX-07、MX-09、MX-10 通过（单测使用 openWithoutHandshake；open() 保留 SABM/UA 握手供 Step 10 与真机）。
- [ ] 固件有 Step 9 专用段落；真机烧录：AT+CMUX=0 成功、SABM/UA 成功、虚拟通道 AT/AT+CSQ 有响应、close 后直连 AT 正常。
- [x] 仓库根目录 `zig build test-cellular`（含 cmux）通过；`zig build test` 全量单测通过。
- [x] 文档 Step 9 标记完成。

---

## 五、与 Step 10 的衔接

Step 10 将实现：  
- Modem 在单通道下调用 Cmux.open（且由 Modem 先发 AT+CMUX=0）；  
- at_engine.setIo(cmux.channelIo(at_dlci))、pppIo() 返回 cmux.channelIo(ppp_dlci)；  
- enterCmux/exitCmux 内 startPump/stopPump 与 close；  
- config.cmux_channels 校验与 DLCI 绑定（R41）。  

Step 9 不实现上述 Modem 侧逻辑，只交付「可独立使用的 Cmux + 单测 + 固件 Step 9 验证」。

---

如无异议，可按此计划开发；若有步骤想合并/延后/拆分，可指出具体编号再调。
