# plan.md 设计文档 Review — 多工程师实施可执行性检查

> 目的：确认每一步是否可按文档实现、依赖是否清晰、是否有需要你确认或补充的地方。

**状态（2026-03-16）：**
- **文档内部不一致**：已全部采纳并改入 plan.md（Step 3/4 标题与目录树统一、ModemInfo 统一、parseResponse 合约、8.9 改为 21 tests、总览表与可选烧录表述）。
- **缺失规格**：**RingBuffer** 已按「两段线性 buffer」方案写入 plan.md。**Control 类型（AtError、SendAtPayload）** 已写入 plan.md §5.8.1：AtError 采用方案 A（at_error 携带 AtStatus，API 返回 error.AtError）；SendAtPayload 采用 buf+len（SEND_AT_BUF_CAP=256）、调用方 serialized_len > CAP 时返回 error.PayloadTooLong、Worker 仅用 buf[0..len] 并可选防御性检查，保证不越界。**request_queue/response_channel** 已写入 plan.md §5.8.1：使用 channel_factory（与 Bus 一致），request_queue 容量 4～8，response_channel 单槽（capacity 0 或 1）。**Step 8 Module 占位** 已写入 plan.md Step 8。**Thread/Notify/Time 合约** 已写入 plan.md §3.7（必选 API 与用途）。无需再拍板项。
- **多工程师并行**：由你自行安排；你将按 Step 逐步实现最小可运行并实时测试。

---

## 一、总体结论

- **可按文档实现**：Step 0～13 的先后顺序、涉及文件、验证方式、通过标准都写得很清楚，工程师按 Step 执行并对照「通过标准」即可。
- **需要你确认/统一的地方**：下面「二」中的命名/数字不一致、「三」中的缺失规格、「四」中的并行与接口假设，建议在开工前拍板一次。

---

## 二、文档内部不一致（建议统一）

### 2.1 文件名 vs 目录树

| 位置 | 写法 | 建议 |
|------|------|------|
| Step 3 标题 | **at_parse.zig** | 与目录树不一致 |
| §4 目录树 / §5.3 | **at/parse.zig** | 以目录树为准 |
| **统一** | 实施时文件名为 `at/parse.zig`；Step 3 标题可改为「parse.zig — AT 响应解析」避免歧义 |

| 位置 | 写法 | 建议 |
|------|------|------|
| Step 4 标题 | **at.zig** | 与目录树不一致 |
| §4 目录树 / §5.5 | **at/engine.zig** | 以目录树为准 |
| **统一** | 实施时文件名为 `at/engine.zig`；Step 4 标题可改为「engine.zig + commands.zig」 |

### 2.2 类型命名：ModemInfo vs ModuleInfo

- **§5.1 types.zig** 只定义 **ModemInfo**（含 imei/model/firmware、getImei/getModel/getFirmware）。
- **§5.4 commands.zig** 与 **§5.11 quectel.zig** 中多处写的是 **types.ModuleInfo**（如 GetManufacturer/GetModel/GetModuleInfo 的 `Response = types.ModuleInfo`）。

**需要你确认**：统一为 **ModemInfo**（即 commands/quectel 里改为 `types.ModemInfo`），还是要在 types 里新增 **ModuleInfo** 并约定与 ModemInfo 的关系？当前文档按「只有 ModemInfo」理解会与 commands/quectel 的代码示例冲突。

### 2.3 命令合约：parse vs parseResponse

- **§5.4 表格** 写的是 **`parse(line)`**。
- **§5.4 / §5.5 代码与 engine 伪代码** 使用的是 **`parseResponse(line)`**。

**建议**：在 5.4 的 Command contract 表里把方法名明确写成 **parseResponse**，与 engine.zig 的 `Cmd.parseResponse(line)` 一致，避免实现时一个用 parse 一个用 parseResponse。

### 2.4 Reducer 测试数量

- **§8.9 标题**：「reducer tests (**18** tests, pure logic, no IO)」
- **§9 Step 7、总览表、R27**：**21** 个测试（CR-01～CR-21）。

**建议**：将 8.9 标题改为「reducer tests (**21** tests, pure logic, no IO)」，与 Step 7 和总览表一致。

---

## 三、缺失或需你拍板的规格

### 3.1 ~~RingBuffer / MockIo 的 RingBuffer 来源~~（已解决）

- **已采纳方案**：MockIo 使用**两段线性 buffer**（与 pkg/net/ws、pkg/net/tls 的 MockConn 风格一致），无 RingBuffer 依赖。
- **plan.md 已更新**：§5.2 移除 `fromBufferPair`；§8.1 规定 MockIo 的 tx_buf/tx_len、rx_buf/rx_len/rx_pos 语义与 feed/sent/drain；全文「ring buffer」改为「两段线性 buffer」或「linear buffers」。

### 3.2 ~~Control 相关类型：AtError、SendAtPayload~~（已解决）

- **已采纳**：AtError 采用方案 A — `ControlResponse.at_error` 携带 **AtStatus**，API 对调用方统一返回 error.AtError（或 error.Timeout）。SendAtPayload 采用 **buf+len**：`struct { buf: [SEND_AT_BUF_CAP]u8, len: usize }`，SEND_AT_BUF_CAP=256；不变式 len ≤ CAP；调用方 serialized_len > CAP 时返回 error.PayloadTooLong 不入队；Worker 仅用 buf[0..len]，可防御性检查防越界。已写入 plan.md §5.8.1。

### 3.3 ~~request_queue / response_channel 的具体类型~~（已解决）

- **已采纳**：request_queue / response_channel 均使用 **runtime/channel_factory**（与 Bus 一致）。request_queue：`ChannelFactory.Channel(ControlRequest).init(allocator, 4)`（或 8）。response_channel：单槽，`Channel(ControlResponse)`，capacity 0 或 1（与 BLE ResponseSlot 单槽语义一致）。已写入 plan.md §5.8.1。

### 3.4 ~~Time / Thread / Notify 的合约与来源~~（已解决）

- **已采纳**：在 plan 中新增 **§3.7 Runtime 合约：Thread / Notify / Time**，列出 Thread（spawn/join/detach、TaskFn、SpawnConfig）、Notify（init/deinit/signal/wait/timedWait）、Time（nowMs/sleepMs）的必选 API 与用途，注明来自 `runtime/thread.zig`、`runtime/sync/notify.zig`、`runtime/time.zig`。Step 8/9/11 实现时按 §3.7 注入即可。

### 3.5 ~~Step 8 的 Modem 泛型与「最小可运行」配置~~（已解决）

- **已采纳**：Step 8 明确使用 **占位 Module**（`quectel_stub.zig`：仅含 Probe 等最少命令，init_sequence 可为空或仅 Probe）与 **gpio=null**；完整 Module（quectel.zig / simcom.zig）在 **Step 12** 实现。已写入 plan.md Step 8「实现内容」与「涉及文件」，烧录验证逻辑中已注明使用 stub + gpio=null。

---

## 四、多工程师并行与依赖

### 4.1 可并行的大块（在接口约定好后）

- **Step 1（types.zig）**：无依赖，可最先做；完成后可作为「类型契约」给所有人用。  
- **Step 2（io.zig + mock.zig）**：仅依赖 types（若 Io 等放在 types 或 io 内）。可与 Step 1 之后并行。  
- **Step 3（at/parse.zig）**：仅依赖 types，可与 Step 2 并行。  
- **Step 4（at/engine.zig + commands.zig）**：依赖 Io、Time、types；依赖 Step 2、Step 3。建议 Step 1/2/3 都完成后再做，或至少 2+3 完成。  
- **Step 5（sim.zig）、Step 6（signal.zig）**：都依赖 AtEngine + commands + parse；可在 Step 4 完成后并行。  
- **Step 7（cellular reducer）**：只依赖 types，可与 Step 4/5/6 并行（只要 types 已定）。  
- **Step 8（modem 路由）**：依赖 Modem 类型（含 Module 占位）、Io、AtEngine；建议 Step 4 完成且 Step 8 的 Module 占位约定清楚后再做。  
- **Step 9（cmux.zig）**：依赖 Io、Thread、Notify；可与 Step 8 并行（若 Thread/Notify 合约已定）。  
- **Step 10**：依赖 Step 8+9，顺序做。  
- **Step 11**：依赖 Step 7+10 及 Control 类型定义，顺序做。  
- **Step 12（quectel/simcom）**：依赖 commands/urcs 和 Modem 的 Module 契约，可在 Step 4 与 8 之后并行于 Step 10/11（接口稳定即可）。  
- **Step 13**：收尾，最后做。

**建议**：在 plan 的「实施计划」开头加一张 **依赖图或表格**（Step X 依赖 Step Y、Z），并注明「Step 8 使用 Module 占位」，方便分工和排期。

### 4.2 固件与 test/unit 的归属

- 烧录验证在 **test/firmware/110-cellular/** 与 **test/esp/110-cellular/**；Mock 在 **test/unit/pkg/cellular/**。
- **test/unit/mod.zig** 目前没有 cellular 的 `_ = @import("pkg/cellular/...")`；Step 13 会加。

**建议**：在 plan 里明确「Step 13 在 test/unit/mod.zig 中新增的条目列表」（例如每个 cellular 测试文件一条），避免漏加或重复。

---

## 五、每一步是否「可按文档实现」的简要结论

| Step | 是否可按文档实现 | 备注 |
|------|------------------|------|
| 0 | 是 | 硬件列表、目录、通过标准清晰；GPIO 编号按 board 配置即可。 |
| 1 | 是 | 类型与测试用例明确；注意 2.2 的 ModemInfo/ModuleInfo 统一。 |
| 2 | 是 | 需在 5.2 或 Step 2 明确 pollFn 为必选；MockIo 已规定两段线性 buffer（§8.1）。 |
| 3 | 是 | 以 parse.zig 为准；Step 3 标题建议与目录树统一。 |
| 4 | 是 | 以 engine.zig + commands.zig 为准；命令合约统一 parseResponse。 |
| 5 | 是 | 依赖 Step 4；sim 的 AT 命令列表在 5.9 和 commands 中可查。 |
| 6 | 是 | 依赖 Step 4；signal 的 AT 命令在 5.10 和 commands 中可查。 |
| 7 | 是 | reducer 规则与 21 个用例明确；8.9 标题改为 21 tests。 |
| 8 | 是 | Step 8 已约定占位 Module（quectel_stub.zig）+ gpio=null（§3.5）。 |
| 9 | 是 | CMUX 帧格式与 pump 线程在 5.6、Q6 有描述；Thread/Notify 合约见 §3.7。 |
| 10 | 是 | 在 8+9 基础上集成；通过标准清晰。 |
| 11 | 是 | Control 与 6.1.1 约束写得很清楚；AtError/SendAtPayload/request_queue/response_channel 已定（§5.8.1）。 |
| 12 | 是 | Module 契约在 5.11 有；注意 ModuleInfo→ModemInfo 若你统一为 ModemInfo。 |
| 13 | 是 | 导出与 121 测试通过标准明确；建议列出要加的 test/unit 条目。 |

---

## 六、需要你确认的清单（建议逐条拍板）

1. **类型命名**：commands/quectel 中统一用 **ModemInfo**（已采纳并改入 plan）。  
2. **RingBuffer**：已采纳「两段线性 buffer」，见 §3.1。  
3. **AtError**：已采纳方案 A（at_error 携带 AtStatus），见 §3.2。  
4. **SendAtPayload**：已采纳 buf+len + PayloadTooLong + 防御性检查，见 §3.2。  
5. **request_queue / response_channel**：已采纳 channel_factory，request_queue 容量 4～8，response_channel 单槽（capacity 0 或 1），见 §3.3。  
6. **Step 8**：已明确采用「占位 Module（quectel_stub.zig）+ gpio=null」，完整 Module 在 Step 12 实现；已写入 plan.md Step 8。  
7. **Thread / Notify 合约**：已在 plan 中增加 §3.7 列出 Thread/Notify/Time 必选 API（§3.4）。  
8. **文档修订**：是否采纳「Step 3/4 标题与目录树统一、8.9 改为 21 tests、5.4 合约写 parseResponse」？（§2.1、§2.3、§2.4）  

以上都确认后，多工程师按 Step 分工实施即可按文档执行；有分歧的地方在 plan 或 plan-review 里记一笔，后续实现就有据可查。
