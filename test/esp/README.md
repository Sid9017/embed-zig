# test/esp — 在 ESP32 上编固件并烧录

本目录下的每个子目录（如 `110-cellular`）是 **ESP 固件工程内容**：提供 main、bsp、board 等，用 esp-zig + ESP-IDF 把 `test/firmware` 里对应的 app 编成可烧录的 .bin。

---

## esp-zig 里其他示例是怎么做的

- 所有示例都 **在 esp-zig 仓库内部**：`examples/hello_world`、`examples/wifi/sta` 等。
- 每个示例有自己的 **build.zig** 和 **build.zig.zon**；zon 里只依赖 `esp = { path = "../.." }`（或 `"../../.."`，视层级而定）。
- 使用方式：**先 cd 到该示例目录**，再执行：
  ```bash
  zig build flash-monitor -Dbuild_config=board/esp32s3_devkit/build_config.zig -Dbsp=board/esp32s3_devkit/bsp.zig -Dport=/dev/cu.usbserial-xxx -Desp_idf=$ESP_IDF -Dtimeout=15
  ```
- 因为构建根在该示例目录，且依赖 `esp` 指向同一仓库内的 esp-zig 根，build.zig 里的 `@import("esp")` 才能生效。

---

## 为什么不能直接在 embed-zig 里对 110-cellular 执行 `zig build`？

110-cellular 的 build.zig 里有 `const esp = @import("esp");`。当构建根是 **embed-zig/test/esp/110-cellular** 时，依赖 `esp` 指向的是**另一个仓库**（esp-zig）。在当前 Zig 构建里，跨仓库的 dependency 不会作为模块名暴露给 build.zig，因此会报 **no module named 'esp'**。所以不能“在 embed-zig 里直接编 110-cellular”而指望和 hello_world 一样用 `@import("esp")`。

---

## 正确做法：在 esp-zig 里加一个“引用 embed-zig 的”示例（与其它 example 一致）

和别的 pkg 示例一样：**在 esp-zig 仓库里新增一个 example**，该 example 依赖 `esp` 和 `embed_zig`，并把 110-cellular 的入口、bsp、board 等放在这个 example 目录下（或通过 symlink 指到 embed-zig），这样：

- 构建根在该 example 目录，`@import("esp")` 可用；
- 不修改 esp-zig 的**根** build.zig，只多一个 example 目录。

**已在 esp-zig 中新增示例 `examples/cellular`**，与其它示例用法一致：

1. 确保 **embed-zig** 与 **esp-zig** 并列（如 `../embed-zig` 相对 esp-zig 根）。若路径不同，改 `esp-zig/examples/cellular/build.zig.zon` 里的 `embed_zig.path`。
2. 进入该示例目录并执行（端口按本机串口修改）：
   ```bash
   cd /path/to/esp-zig/examples/cellular
   zig build flash-monitor -Dbuild_config=board/esp32s3_devkit/build_config.zig -Dbsp=board/esp32s3_devkit/bsp.zig -Dport=/dev/cu.usbserial-xxx -Desp_idf=$ESP_IDF -Dtimeout=15
   ```

该示例依赖 `esp` 与 `embed_zig`，应用逻辑来自 embed-zig 的 `test/firmware/110-cellular/app.zig`，无需修改 esp-zig 的根 build.zig。
