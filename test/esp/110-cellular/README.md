# 110-cellular ESP 固件

4G cellular 模组固件骨架，用于 Step 2 及后续烧录验证。

## 固件内 Mock 测试怎么运行

固件里的 mock 测试写在 **test/firmware/110-cellular/app.zig** 中，名字是 `test "run with mock hw"`。  
该测试用 `MockIo` 模拟 UART，不接真实硬件即可验证 `run()` 的流程（fromUart → write → read → log）。

### 推荐：在 embed-zig 根目录运行（无需 esp-zig）

```bash
cd /path/to/embed-zig
zig build test-110-cellular-firmware
```

- 该 step 在 **embed-zig 根目录的 build.zig** 里定义。
- 使用 `esp_mock.zig` 提供 `@import("esp").embed`，不依赖 esp-zig，即可跑通 `test "run with mock hw"`。

### 为何在 test/esp/110-cellular 下 `zig build test-firmware` 会报错？

在 **test/esp/110-cellular** 下执行 `zig build` 时，当前目录的 **build.zig** 会被执行，其中有一行 `const esp = @import("esp");`。  
Zig 的 build 脚本**不会**把 build.zig.zon 里的 dependency 自动变成可 `@import` 的模块，所以会报 **no module named 'esp'**。  
因此「固件 mock 测试」改为在 **embed-zig 根目录** 用 `zig build test-110-cellular-firmware` 跑；真正编固件、烧录则需要在 **esp-zig** 里用其 build 系统编本 app（若 esp-zig 支持指定外部 app 路径）。

### 若要在 esp-zig 里编固件或跑 test-firmware

- 需在 **esp-zig** 仓库里配置/构建，让它的 build 把本 app 当作外部 app 编进去（具体见 esp-zig 文档）。
- build.zig.zon 里 esp 路径已设为 `../../../esp-zig`（相对 test/esp/110-cellular），指向与 embed-zig 同级的 esp-zig。
- **Main task 栈**：进入 CMUX 后 main 任务栈用量较大（modem + at_engine + cmux 等）。embed-zig 里 `board/esp32s3_devkit/build_config.zig` 已将 main task 栈设为 16384。若在 esp-zig 中用其他板（如 h106_tiga_v4），需在该板的 build_config 中设置 `main_task_stack_size` / `esp_main_task_stack_size` ≥ 8192（建议 16384），否则会出现 stack overflow。

### 小结

| 想验证的内容           | 在哪里跑               | 命令 |
|------------------------|------------------------|------|
| Io / fromUart 行为     | embed-zig 单元测试     | `cd embed-zig/test/unit && zig build test` |
| 固件 `run()` + mock 机 | **embed-zig 根目录**   | `cd embed-zig && zig build test-110-cellular-firmware` |
| 真机烧录               | esp-zig 构建 + 烧录    | 在 esp-zig 中配置本 app 后编固件并烧录到 ESP32S3 |
