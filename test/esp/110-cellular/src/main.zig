const board_hw = @import("board_hw");
const test_firmware = @import("test_firmware");

export fn zig_esp_main() callconv(.c) void {
    test_firmware.run(board_hw, .{});
}
