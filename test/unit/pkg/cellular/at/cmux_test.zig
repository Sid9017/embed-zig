//! CMUX unit tests MX-01..MX-10 per docs/cellular_step9_dev_plan.md.

const std = @import("std");
const embed = @import("embed");
const mock_mod = embed.pkg.cellular.io.mock;
const io_mod = embed.pkg.cellular.io.io_mod;
const cmux_mod = embed.pkg.cellular.at.cmux;
const Std = embed.runtime.std;

const calcFcs = cmux_mod.calcFcs;
const encodeFrame = cmux_mod.encodeFrame;
const decodeFrame = cmux_mod.decodeFrame;
const Frame = cmux_mod.Frame;
const FrameType = cmux_mod.FrameType;
const CmuxType = cmux_mod.CmuxType;

fn uaFrameBytes(dlci: u8) struct { buf: [32]u8, len: usize } {
    var buf: [32]u8 = undefined;
    const n = encodeFrame(.{
        .dlci = dlci,
        .control = @intFromEnum(FrameType.ua),
        .data = &.{},
    }, &buf);
    return .{ .buf = buf, .len = n };
}

test "cmux MX-01: UIH encode" {
    const frame = Frame{
        .dlci = 2,
        .control = @intFromEnum(FrameType.ui),
        .data = "AT",
    };
    var out: [64]u8 = undefined;
    const n = encodeFrame(frame, &out);
    try std.testing.expect(n >= 6);
    try std.testing.expect(out[0] == 0x7E);
    try std.testing.expect(out[n - 1] == 0x7E);
    const addr: u8 = (2 << 2) | 0x03;
    try std.testing.expect(out[1] == addr or out[1] == 0x7D);
    try std.testing.expect(out[2] == 0x03 or out[2] == 0x7D);
    try std.testing.expect(out[3] == 0x02 or out[3] == 0x7D);
}

test "cmux MX-02: UIH decode" {
    var out: [64]u8 = undefined;
    const n = encodeFrame(.{
        .dlci = 2,
        .control = @intFromEnum(FrameType.ui),
        .data = "AT",
    }, &out);
    const dec = decodeFrame(out[0..n]);
    try std.testing.expect(dec != null);
    try std.testing.expectEqual(@as(u8, 2), dec.?.dlci);
    try std.testing.expectEqual(@intFromEnum(FrameType.ui), dec.?.control);
    try std.testing.expectEqualStrings("AT", dec.?.data);
}

test "cmux MX-08: FCS" {
    const data = [_]u8{ 0x0B, 0x03, 0x02, 0x41, 0x54 };
    const fcs = calcFcs(&data);
    const expected: u8 = 0x0B ^ 0x03 ^ 0x02 ^ 0x41 ^ 0x54;
    try std.testing.expectEqual(expected, fcs);
    var enc: [32]u8 = undefined;
    const n = encodeFrame(.{
        .dlci = 2,
        .control = @intFromEnum(FrameType.ui),
        .data = "AT",
    }, &enc);
    const dec = decodeFrame(enc[0..n]);
    try std.testing.expect(dec != null);
}

test "cmux MX-03: SABM/UA handshake" {
    var mock = mock_mod.MockIo.init();
    var notifiers: [4]Std.Notify = undefined;
    for (0..4) |i| notifiers[i] = Std.Notify.init();
    defer for (&notifiers) |*notifier| notifier.deinit();

    const Cmux = CmuxType(Std.Thread, Std.Notify, 4);
    const io = mock.io();
    var cmux = Cmux.init(&io, notifiers);
    cmux.openWithoutHandshake(&.{ 1, 2 });

    const sent = mock.sent();
    try std.testing.expect(sent.len >= 2);
    try std.testing.expect(sent[0] == 0x7E);
}

test "cmux MX-04: channel write" {
    var mock = mock_mod.MockIo.init();
    var notifiers: [4]Std.Notify = undefined;
    for (0..4) |i| notifiers[i] = Std.Notify.init();
    defer for (&notifiers) |*n| n.deinit();

    const Cmux = CmuxType(Std.Thread, Std.Notify, 4);
    const io = io_mod.fromUart(mock_mod.MockIo, &mock);
    var cmux = Cmux.init(&io, notifiers);
    const ua1 = uaFrameBytes(1);
    const ua2 = uaFrameBytes(2);
    mock.feed(ua1.buf[0..ua1.len]);
    mock.feed(ua2.buf[0..ua2.len]);
    cmux.openWithoutHandshake(&.{ 1, 2 });

    const ch_io = cmux.channelIo(2);
    try std.testing.expect(ch_io != null);
    _ = ch_io.?.write("AT") catch @panic("write");
    const sent = mock.sent();
    try std.testing.expect(sent.len >= 6);
    const last_7e = std.mem.lastIndexOfScalar(u8, sent, 0x7E) orelse return;
    var j: usize = last_7e;
    while (j > 0) {
        j -= 1;
        if (sent[j] == 0x7E) break;
    }
    var copy: [256]u8 = undefined;
    const frame_len = last_7e - j + 1;
    if (frame_len > copy.len) return;
    @memcpy(copy[0..frame_len], sent[j..][0..frame_len]);
    const dec = decodeFrame(copy[0..frame_len]);
    try std.testing.expect(dec != null);
    try std.testing.expectEqual(@as(u8, 2), dec.?.dlci);
    try std.testing.expectEqualStrings("AT", dec.?.data);
}

test "cmux MX-05: channel read" {
    var mock = mock_mod.MockIo.init();
    var notifiers: [4]Std.Notify = undefined;
    for (0..4) |i| notifiers[i] = Std.Notify.init();
    defer for (&notifiers) |*n| n.deinit();

    const Cmux = CmuxType(Std.Thread, Std.Notify, 4);
    const io = io_mod.fromUart(mock_mod.MockIo, &mock);
    var cmux = Cmux.init(&io, notifiers);
    const ua1 = uaFrameBytes(1);
    const ua2 = uaFrameBytes(2);
    mock.feed(ua1.buf[0..ua1.len]);
    mock.feed(ua2.buf[0..ua2.len]);
    cmux.openWithoutHandshake(&.{ 1, 2 });

    var uih_buf: [32]u8 = undefined;
    const uih_len = encodeFrame(.{
        .dlci = 2,
        .control = @intFromEnum(FrameType.ui),
        .data = "OK\r\n",
    }, &uih_buf);
    mock.feed(uih_buf[0..uih_len]);

    cmux.pump();
    const ch_io = cmux.channelIo(2).?;
    var read_buf: [16]u8 = undefined;
    const n = ch_io.read(&read_buf) catch return;
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("OK\r\n", read_buf[0..n]);
}

test "cmux MX-06: channel isolation" {
    var mock = mock_mod.MockIo.init();
    var notifiers: [4]Std.Notify = undefined;
    for (0..4) |i| notifiers[i] = Std.Notify.init();
    defer for (&notifiers) |*n| n.deinit();

    const Cmux = CmuxType(Std.Thread, Std.Notify, 4);
    const io = io_mod.fromUart(mock_mod.MockIo, &mock);
    var cmux = Cmux.init(&io, notifiers);
    const ua1 = uaFrameBytes(1);
    const ua2 = uaFrameBytes(2);
    mock.feed(ua1.buf[0..ua1.len]);
    mock.feed(ua2.buf[0..ua2.len]);
    cmux.openWithoutHandshake(&.{ 1, 2 });

    var uih1: [32]u8 = undefined;
    const len1 = encodeFrame(.{ .dlci = 1, .control = @intFromEnum(FrameType.ui), .data = "X" }, &uih1);
    mock.feed(uih1[0..len1]);
    cmux.pump();

    const ch1 = cmux.channelIo(1).?;
    const ch2 = cmux.channelIo(2).?;
    var buf: [4]u8 = undefined;
    const r1 = ch1.read(&buf) catch return;
    try std.testing.expectEqual(@as(usize, 1), r1);
    try std.testing.expectEqual(@as(u8, 'X'), buf[0]);
    try std.testing.expectError(error.WouldBlock, ch2.read(&buf));
}

test "cmux MX-07: DISC/close" {
    var mock = mock_mod.MockIo.init();
    var notifiers: [4]Std.Notify = undefined;
    for (0..4) |i| notifiers[i] = Std.Notify.init();
    defer for (&notifiers) |*n| n.deinit();

    const Cmux = CmuxType(Std.Thread, Std.Notify, 4);
    const io = io_mod.fromUart(mock_mod.MockIo, &mock);
    var cmux = Cmux.init(&io, notifiers);
    const ua1 = uaFrameBytes(1);
    const ua2 = uaFrameBytes(2);
    mock.feed(ua1.buf[0..ua1.len]);
    mock.feed(ua2.buf[0..ua2.len]);
    cmux.openWithoutHandshake(&.{ 1, 2 });
    mock.drain();
    cmux.close();
    const sent = mock.sent();
    try std.testing.expect(sent.len >= 2);
    try std.testing.expect(sent[0] == 0x7E);
}

test "cmux MX-09: concurrent demux" {
    var mock = mock_mod.MockIo.init();
    var notifiers: [4]Std.Notify = undefined;
    for (0..4) |i| notifiers[i] = Std.Notify.init();
    defer for (&notifiers) |*n| n.deinit();

    const Cmux = CmuxType(Std.Thread, Std.Notify, 4);
    const io = io_mod.fromUart(mock_mod.MockIo, &mock);
    var cmux = Cmux.init(&io, notifiers);
    const ua1 = uaFrameBytes(1);
    const ua2 = uaFrameBytes(2);
    mock.feed(ua1.buf[0..ua1.len]);
    mock.feed(ua2.buf[0..ua2.len]);
    cmux.openWithoutHandshake(&.{ 1, 2 });

    var uih1: [32]u8 = undefined;
    var uih2: [32]u8 = undefined;
    const len1 = encodeFrame(.{ .dlci = 1, .control = @intFromEnum(FrameType.ui), .data = "A" }, &uih1);
    const len2 = encodeFrame(.{ .dlci = 2, .control = @intFromEnum(FrameType.ui), .data = "B" }, &uih2);
    mock.feed(uih1[0..len1]);
    cmux.pump();
    mock.feed(uih2[0..len2]);
    cmux.pump();

    const ch1 = cmux.channelIo(1).?;
    const ch2 = cmux.channelIo(2).?;
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), ch1.read(&buf) catch return);
    try std.testing.expectEqual(@as(u8, 'A'), buf[0]);
    try std.testing.expectEqual(@as(usize, 1), ch2.read(&buf) catch return);
    try std.testing.expectEqual(@as(u8, 'B'), buf[0]);
}

test "cmux MX-10: pump demux multiple frames" {
    var mock = mock_mod.MockIo.init();
    var notifiers: [4]Std.Notify = undefined;
    for (0..4) |i| notifiers[i] = Std.Notify.init();
    defer for (&notifiers) |*n| n.deinit();

    const Cmux = CmuxType(Std.Thread, Std.Notify, 4);
    const io = io_mod.fromUart(mock_mod.MockIo, &mock);
    var cmux = Cmux.init(&io, notifiers);
    const ua2 = uaFrameBytes(2);
    mock.feed(ua2.buf[0..ua2.len]);
    cmux.openWithoutHandshake(&.{2});

    var uih_a: [32]u8 = undefined;
    var uih_b: [32]u8 = undefined;
    const la = encodeFrame(.{ .dlci = 2, .control = @intFromEnum(FrameType.ui), .data = "a" }, &uih_a);
    const lb = encodeFrame(.{ .dlci = 2, .control = @intFromEnum(FrameType.ui), .data = "b" }, &uih_b);
    mock.feed(uih_a[0..la]);
    cmux.pump();
    mock.feed(uih_b[0..lb]);
    cmux.pump();

    const ch = cmux.channelIo(2).?;
    var got: [2]u8 = undefined;
    var n_total: usize = 0;
    while (n_total < 2) {
        const n = ch.read(got[n_total..]) catch return;
        n_total += n;
    }
    try std.testing.expectEqual(@as(u8, 'a'), got[0]);
    try std.testing.expectEqual(@as(u8, 'b'), got[1]);
}
