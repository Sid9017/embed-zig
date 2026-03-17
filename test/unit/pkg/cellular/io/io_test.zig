//! Io interface and fromUart unit tests. Step 2: IO-01 round-trip, IO-02 fromUart, IO-03 WouldBlock.

const std = @import("std");
const embed = @import("embed");
const io_mod = embed.pkg.cellular.io.io_mod;
const mock_mod = embed.pkg.cellular.io.mock;

test "IO-01: Io round-trip (MockIo write then read)" {
    var mock = mock_mod.MockIo.init();
    mock.feed("OK\r\n");
    const io = mock.io();

    var buf: [64]u8 = undefined;
    const n_read = try io.read(&buf);
    try std.testing.expectEqual(@as(usize, 4), n_read);
    try std.testing.expectEqualStrings("OK\r\n", buf[0..n_read]);

    const n_write = try io.write("AT\r\n");
    try std.testing.expectEqual(@as(usize, 4), n_write);
    try std.testing.expectEqualStrings("AT\r\n", mock.sent());
}

test "IO-02: fromUart (Mock UART HAL wrapped as Io, read/write pass through)" {
    var mock = mock_mod.MockIo.init();
    mock.feed("+CSQ: 20,0\r\n");
    const io = io_mod.fromUart(mock_mod.MockIo, &mock);

    const n_write = try io.write("AT+CSQ\r\n");
    try std.testing.expectEqual(@as(usize, 8), n_write);
    try std.testing.expectEqualStrings("AT+CSQ\r\n", mock.sent());

    var buf: [128]u8 = undefined;
    const n_read = try io.read(&buf);
    try std.testing.expectEqual(@as(usize, 12), n_read);
    try std.testing.expectEqualStrings("+CSQ: 20,0\r\n", buf[0..n_read]);
}

test "IO-03: WouldBlock (empty MockIo read returns WouldBlock)" {
    var mock = mock_mod.MockIo.init();
    const io = mock.io();

    var buf: [8]u8 = undefined;
    const result = io.read(&buf);
    try std.testing.expectError(error.WouldBlock, result);
}
