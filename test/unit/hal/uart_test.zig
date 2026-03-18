const std = @import("std");
const testing = std.testing;
const embed = @import("embed");

const uart_mod = embed.hal.uart;

test "uart wrapper" {
    const Mock = struct {
        tx: [16]u8 = [_]u8{0} ** 16,
        tx_len: usize = 0,
        rx: [16]u8 = [_]u8{ 'O', 'K', 0 } ++ [_]u8{0} ** 13,
        rx_len: usize = 2,

        pub fn read(self: *@This(), buf: []u8) uart_mod.Error!usize {
            if (self.rx_len == 0) return error.WouldBlock;
            const n = @min(buf.len, self.rx_len);
            @memcpy(buf[0..n], self.rx[0..n]);
            self.rx_len = 0;
            return n;
        }
        pub fn write(self: *@This(), buf: []const u8) uart_mod.Error!usize {
            const n = @min(buf.len, self.tx.len);
            @memcpy(self.tx[0..n], buf[0..n]);
            self.tx_len = n;
            return n;
        }
        pub fn poll(self: *@This(), flags: uart_mod.PollFlags, _: i32) uart_mod.PollFlags {
            return .{ .readable = flags.readable and self.rx_len > 0, .writable = flags.writable };
        }
    };

    const Uart = uart_mod.from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "uart.test" };
    });

    var d = Mock{};
    var uart = Uart.init(&d);

    const out = [_]u8{ 'H', 'i' };
    _ = try uart.write(&out);
    try std.testing.expectEqual(@as(usize, 2), d.tx_len);

    var in: [4]u8 = undefined;
    const n = try uart.read(&in);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(u8, "OK", in[0..2]);
}
