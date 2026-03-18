const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const xfer = embed.pkg.ble.xfer;

fn ReadX(comptime T: type) type {
    return xfer.read_x.ReadX(T);
}
fn WriteX(comptime T: type) type {
    return xfer.write_x.WriteX(T);
}

const MockTransport = struct {
    const max_sent_data: usize = 16384;
    const max_sent_entries: usize = 256;
    const max_recv_entries: usize = 64;
    const max_recv_data: usize = 4096;

    sent_data: [max_sent_data]u8 = undefined,
    sent_lens: [max_sent_entries]usize = undefined,
    sent_count: usize = 0,
    sent_data_size: usize = 0,

    recv_items: [max_recv_entries]RecvItem = undefined,
    recv_count: usize = 0,
    recv_idx: usize = 0,
    recv_data_buf: [max_recv_data]u8 = undefined,
    recv_data_offset: usize = 0,

    const RecvItem = struct {
        offset: usize,
        len: usize,
        is_timeout: bool,
    };

    pub fn send(self: *MockTransport, data: []const u8) error{Overflow}!void {
        if (self.sent_count >= max_sent_entries) return error.Overflow;
        if (self.sent_data_size + data.len > max_sent_data) return error.Overflow;
        @memcpy(self.sent_data[self.sent_data_size .. self.sent_data_size + data.len], data);
        self.sent_lens[self.sent_count] = data.len;
        self.sent_count += 1;
        self.sent_data_size += data.len;
    }

    pub fn recv(self: *MockTransport, buf: []u8, timeout_ms: u32) error{Overflow}!?usize {
        _ = timeout_ms;
        if (self.recv_idx >= self.recv_count) return null;
        const item = self.recv_items[self.recv_idx];
        self.recv_idx += 1;
        if (item.is_timeout) return null;
        if (item.len > buf.len) return error.Overflow;
        @memcpy(buf[0..item.len], self.recv_data_buf[item.offset .. item.offset + item.len]);
        return item.len;
    }

    fn scriptRecv(self: *MockTransport, data: []const u8) void {
        self.recv_items[self.recv_count] = .{
            .offset = self.recv_data_offset,
            .len = data.len,
            .is_timeout = false,
        };
        @memcpy(
            self.recv_data_buf[self.recv_data_offset .. self.recv_data_offset + data.len],
            data,
        );
        self.recv_data_offset += data.len;
        self.recv_count += 1;
    }

    fn scriptTimeout(self: *MockTransport) void {
        self.recv_items[self.recv_count] = .{ .offset = 0, .len = 0, .is_timeout = true };
        self.recv_count += 1;
    }

    fn getSent(self: *const MockTransport, idx: usize) []const u8 {
        var offset: usize = 0;
        for (self.sent_lens[0..idx]) |l| {
            offset += l;
        }
        return self.sent_data[offset .. offset + self.sent_lens[idx]];
    }
};

fn buildChunkPacket(buf: []u8, total: u16, seq: u16, payload: []const u8) []u8 {
    const hdr = (xfer.chunk.Header{ .total = total, .seq = seq }).encode();
    @memcpy(buf[0..chunk.header_size], &hdr);
    @memcpy(buf[xfer.chunk.header_size .. xfer.chunk.header_size + payload.len], payload);
    return buf[0 .. xfer.chunk.header_size + payload.len];
}

// ============================================================================
// ReadX Tests
// ============================================================================

test "ReadX: basic transfer with immediate ACK" {
    var mock = MockTransport{};
    mock.scriptRecv(&xfer.chunk.start_magic);
    mock.scriptRecv(&xfer.chunk.ack_signal);

    const data = "Hello, BLE World!";
    var rx = ReadX(MockTransport).init(&mock, data, .{
        .mtu = 50,
        .send_redundancy = 1,
    });
    try rx.run();

    const dcs = xfer.chunk.dataChunkSize(50);
    const expected_chunks = xfer.chunk.chunksNeeded(data.len, 50);
    try std.testing.expectEqual(expected_chunks, mock.sent_count);

    const first_sent = mock.getSent(0);
    const hdr = xfer.chunk.Header.decode(first_sent[0..chunk.header_size]);
    try std.testing.expectEqual(@as(u16, @intCast(expected_chunks)), hdr.total);
    try std.testing.expectEqual(@as(u16, 1), hdr.seq);

    const expected_payload_len = @min(data.len, dcs);
    try std.testing.expectEqualSlices(
        u8,
        data[0..expected_payload_len],
        first_sent[xfer.chunk.header_size..],
    );
}

test "ReadX: transfer with retransmission" {
    var mock = MockTransport{};
    mock.scriptRecv(&xfer.chunk.start_magic);

    var loss_buf: [2]u8 = undefined;
    _ = xfer.chunk.encodeLossList(&.{2}, &loss_buf);
    mock.scriptRecv(&loss_buf);

    mock.scriptRecv(&xfer.chunk.ack_signal);

    const data = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnop";
    const mtu: u16 = 30;
    var rx = ReadX(MockTransport).init(&mock, data, .{
        .mtu = mtu,
        .send_redundancy = 1,
    });
    try rx.run();

    const total = xfer.chunk.chunksNeeded(data.len, mtu);
    try std.testing.expectEqual(total + 1, mock.sent_count);

    const retransmit = mock.getSent(total);
    const hdr = xfer.chunk.Header.decode(retransmit[0..chunk.header_size]);
    try std.testing.expectEqual(@as(u16, 2), hdr.seq);
}

test "ReadX: send redundancy sends each xfer.chunk N times" {
    var mock = MockTransport{};
    mock.scriptRecv(&xfer.chunk.start_magic);
    mock.scriptRecv(&xfer.chunk.ack_signal);

    const data = "Short";
    var rx = ReadX(MockTransport).init(&mock, data, .{
        .mtu = 50,
        .send_redundancy = 3,
    });
    try rx.run();

    try std.testing.expectEqual(@as(usize, 3), mock.sent_count);

    const first = mock.getSent(0);
    const second = mock.getSent(1);
    const third = mock.getSent(2);
    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expectEqualSlices(u8, first, third);
}

test "ReadX: timeout waiting for start magic" {
    var mock = MockTransport{};
    mock.scriptTimeout();

    const data = "test";
    var rx = ReadX(MockTransport).init(&mock, data, .{ .mtu = 50, .send_redundancy = 1 });
    try std.testing.expectError(error.Timeout, rx.run());
}

test "ReadX: invalid start magic" {
    var mock = MockTransport{};
    mock.scriptRecv(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });

    const data = "test";
    var rx = ReadX(MockTransport).init(&mock, data, .{ .mtu = 50, .send_redundancy = 1 });
    try std.testing.expectError(error.InvalidStartMagic, rx.run());
}

test "ReadX: empty data returns error" {
    var mock = MockTransport{};
    var rx = ReadX(MockTransport).init(&mock, "", .{ .mtu = 50, .send_redundancy = 1 });
    try std.testing.expectError(error.EmptyData, rx.run());
}

// ============================================================================
// WriteX Tests
// ============================================================================

test "WriteX: basic receive with immediate ACK" {
    const mtu: u16 = 50;
    const dcs = xfer.chunk.dataChunkSize(mtu);
    const data = "Hello from client! This is chunked data.";
    const total: u16 = @intCast(xfer.chunk.chunksNeeded(data.len, mtu));

    var mock = MockTransport{};

    var i: u16 = 0;
    while (i < total) : (i += 1) {
        var pkt: [xfer.chunk.max_mtu]u8 = undefined;
        const seq: u16 = i + 1;
        const offset: usize = @as(usize, i) * dcs;
        const remaining = data.len - offset;
        const payload_len: usize = @min(remaining, dcs);
        const pkt_slice = buildChunkPacket(&pkt, total, seq, data[offset .. offset + payload_len]);
        mock.scriptRecv(pkt_slice);
    }

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = mtu });
    const result = try wx.run();

    try std.testing.expectEqualSlices(u8, data, result.data);
    try std.testing.expectEqual(@as(usize, 1), mock.sent_count);
    try std.testing.expectEqualSlices(u8, &xfer.chunk.ack_signal, mock.getSent(0));
}

test "WriteX: receive with timeout and loss list" {
    const mtu: u16 = 30;
    const dcs = xfer.chunk.dataChunkSize(mtu);
    const data = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklm";
    const total: u16 = @intCast(xfer.chunk.chunksNeeded(data.len, mtu));
    try std.testing.expect(total >= 2);

    var mock = MockTransport{};

    {
        var pkt: [xfer.chunk.max_mtu]u8 = undefined;
        const payload_len: usize = @min(data.len, dcs);
        const pkt_slice = buildChunkPacket(&pkt, total, 1, data[0..payload_len]);
        mock.scriptRecv(pkt_slice);
    }

    mock.scriptTimeout();

    var seq: u16 = 2;
    while (seq <= total) : (seq += 1) {
        var pkt: [xfer.chunk.max_mtu]u8 = undefined;
        const offset: usize = @as(usize, seq - 1) * dcs;
        const remaining = data.len - offset;
        const payload_len: usize = @min(remaining, dcs);
        const pkt_slice = buildChunkPacket(&pkt, total, seq, data[offset .. offset + payload_len]);
        mock.scriptRecv(pkt_slice);
    }

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = mtu });
    const result = try wx.run();

    try std.testing.expectEqualSlices(u8, data, result.data);
    try std.testing.expect(mock.sent_count >= 2);

    const loss_msg = mock.getSent(0);
    try std.testing.expect(loss_msg.len >= 2);
    var decoded_seqs: [16]u16 = undefined;
    const decoded_count = xfer.chunk.decodeLossList(loss_msg, &decoded_seqs);
    try std.testing.expect(decoded_count >= 1);
    try std.testing.expectEqual(@as(u16, 2), decoded_seqs[0]);

    try std.testing.expectEqualSlices(u8, &xfer.chunk.ack_signal, mock.getSent(mock.sent_count - 1));
}

test "WriteX: out-of-order chunks" {
    const mtu: u16 = 30;
    const dcs = xfer.chunk.dataChunkSize(mtu);
    const data = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklm";
    const total: u16 = @intCast(xfer.chunk.chunksNeeded(data.len, mtu));

    var mock = MockTransport{};

    var seq: u16 = total;
    while (seq >= 1) : (seq -= 1) {
        var pkt: [xfer.chunk.max_mtu]u8 = undefined;
        const offset: usize = @as(usize, seq - 1) * dcs;
        const remaining = data.len - offset;
        const payload_len: usize = @min(remaining, dcs);
        const pkt_slice = buildChunkPacket(&pkt, total, seq, data[offset .. offset + payload_len]);
        mock.scriptRecv(pkt_slice);
        if (seq == 1) break;
    }

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = mtu });
    const result = try wx.run();

    try std.testing.expectEqualSlices(u8, data, result.data);
}

test "WriteX: timeout gives up after max retries" {
    var mock = MockTransport{};
    for (0..5) |_| {
        mock.scriptTimeout();
    }

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{
        .mtu = 50,
        .max_retries = 5,
    });
    try std.testing.expectError(error.Timeout, wx.run());
}

test "WriteX: duplicate chunks are handled idempotently" {
    const mtu: u16 = 50;
    const dcs = xfer.chunk.dataChunkSize(mtu);
    const data = "Hello duplicate world!";
    const total: u16 = @intCast(xfer.chunk.chunksNeeded(data.len, mtu));

    var mock = MockTransport{};

    for (0..3) |_| {
        var pkt: [xfer.chunk.max_mtu]u8 = undefined;
        const payload_len: usize = @min(data.len, dcs);
        const pkt_slice = buildChunkPacket(&pkt, total, 1, data[0..payload_len]);
        mock.scriptRecv(pkt_slice);
    }

    var seq: u16 = 2;
    while (seq <= total) : (seq += 1) {
        var pkt: [xfer.chunk.max_mtu]u8 = undefined;
        const offset: usize = @as(usize, seq - 1) * dcs;
        const remaining = data.len - offset;
        const payload_len: usize = @min(remaining, dcs);
        const pkt_slice = buildChunkPacket(&pkt, total, seq, data[offset .. offset + payload_len]);
        mock.scriptRecv(pkt_slice);
    }

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = mtu });
    const result = try wx.run();

    try std.testing.expectEqualSlices(u8, data, result.data);
}

// ============================================================================
// ReadX Edge Cases
// ============================================================================

test "ReadX: single byte data produces exactly one chunk" {
    var mock = MockTransport{};
    mock.scriptRecv(&xfer.chunk.start_magic);
    mock.scriptRecv(&xfer.chunk.ack_signal);

    var rx = ReadX(MockTransport).init(&mock, "X", .{ .mtu = 247, .send_redundancy = 1 });
    try rx.run();

    try std.testing.expectEqual(@as(usize, 1), mock.sent_count);
    const sent = mock.getSent(0);
    const hdr = xfer.chunk.Header.decode(sent[0..chunk.header_size]);
    try std.testing.expectEqual(@as(u16, 1), hdr.total);
    try std.testing.expectEqual(@as(u16, 1), hdr.seq);
    try std.testing.expectEqualSlices(u8, "X", sent[xfer.chunk.header_size..]);
}

test "ReadX: data exactly fills one xfer.chunk (MTU boundary)" {
    const mtu: u16 = 30;
    const dcs = comptime xfer.chunk.dataChunkSize(30);
    var data: [dcs]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i % 256);

    var mock = MockTransport{};
    mock.scriptRecv(&xfer.chunk.start_magic);
    mock.scriptRecv(&xfer.chunk.ack_signal);

    var rx = ReadX(MockTransport).init(&mock, &data, .{ .mtu = mtu, .send_redundancy = 1 });
    try rx.run();

    try std.testing.expectEqual(@as(usize, 1), mock.sent_count);
}

test "ReadX: data one byte over xfer.chunk boundary produces two chunks" {
    const mtu: u16 = 30;
    const dcs = comptime xfer.chunk.dataChunkSize(30);
    var data: [dcs + 1]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i % 256);

    var mock = MockTransport{};
    mock.scriptRecv(&xfer.chunk.start_magic);
    mock.scriptRecv(&xfer.chunk.ack_signal);

    var rx = ReadX(MockTransport).init(&mock, &data, .{ .mtu = mtu, .send_redundancy = 1 });
    try rx.run();

    try std.testing.expectEqual(@as(usize, 2), mock.sent_count);

    const last = mock.getSent(1);
    try std.testing.expectEqual(@as(usize, xfer.chunk.header_size + 1), last.len);
}

test "ReadX: ACK timeout after sending chunks" {
    var mock = MockTransport{};
    mock.scriptRecv(&xfer.chunk.start_magic);
    mock.scriptTimeout();

    const data = "test data";
    var rx = ReadX(MockTransport).init(&mock, data, .{ .mtu = 50, .send_redundancy = 1 });
    try std.testing.expectError(error.Timeout, rx.run());

    try std.testing.expect(mock.sent_count > 0);
}

test "ReadX: empty loss list from client is rejected" {
    var mock = MockTransport{};
    mock.scriptRecv(&xfer.chunk.start_magic);
    mock.scriptRecv(&[_]u8{});

    const data = "test data for invalid response";
    var rx = ReadX(MockTransport).init(&mock, data, .{ .mtu = 50, .send_redundancy = 1 });
    try std.testing.expectError(error.InvalidResponse, rx.run());
}

test "ReadX: multiple retransmission rounds" {
    var mock = MockTransport{};
    mock.scriptRecv(&xfer.chunk.start_magic);

    var loss1: [2]u8 = undefined;
    _ = xfer.chunk.encodeLossList(&.{2}, &loss1);
    mock.scriptRecv(&loss1);

    var loss2: [2]u8 = undefined;
    _ = xfer.chunk.encodeLossList(&.{3}, &loss2);
    mock.scriptRecv(&loss2);

    mock.scriptRecv(&xfer.chunk.ack_signal);

    const data = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz01234567";
    const mtu: u16 = 30;
    var rx = ReadX(MockTransport).init(&mock, data, .{ .mtu = mtu, .send_redundancy = 1 });
    try rx.run();

    const total = xfer.chunk.chunksNeeded(data.len, mtu);
    try std.testing.expectEqual(total + 2, mock.sent_count);
}

test "ReadX: minimum MTU (7) still works" {
    var mock = MockTransport{};
    mock.scriptRecv(&xfer.chunk.start_magic);
    mock.scriptRecv(&xfer.chunk.ack_signal);

    const data = "ABCDE";
    var rx = ReadX(MockTransport).init(&mock, data, .{ .mtu = 7, .send_redundancy = 1 });
    try rx.run();

    try std.testing.expectEqual(xfer.chunk.chunksNeeded(data.len, 7), mock.sent_count);
}

// ============================================================================
// WriteX Edge Cases
// ============================================================================

test "WriteX: single byte transfer" {
    const mtu: u16 = 247;
    var mock = MockTransport{};

    var pkt: [xfer.chunk.max_mtu]u8 = undefined;
    const pkt_slice = buildChunkPacket(&pkt, 1, 1, "Z");
    mock.scriptRecv(pkt_slice);

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = mtu });
    const result = try wx.run();

    try std.testing.expectEqualSlices(u8, "Z", result.data);
}

test "WriteX: packet too short (below header size)" {
    var mock = MockTransport{};
    mock.scriptRecv(&[_]u8{ 0x00, 0x01 });

    var recv_buf: [64]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = 50 });
    try std.testing.expectError(error.InvalidPacket, wx.run());
}

test "WriteX: xfer.chunk exceeds MTU" {
    const mtu: u16 = 10;

    var mock = MockTransport{};
    var pkt_buf: [xfer.chunk.max_mtu]u8 = undefined;
    var payload: [32]u8 = undefined;
    @memset(&payload, 0xAB);
    const pkt_slice = buildChunkPacket(&pkt_buf, 1, 1, &payload);
    mock.scriptRecv(pkt_slice);

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = mtu });
    try std.testing.expectError(error.ChunkTooLarge, wx.run());
}

test "WriteX: recv buffer too small" {
    const mtu: u16 = 50;

    var mock = MockTransport{};
    var pkt: [xfer.chunk.max_mtu]u8 = undefined;
    var payload: [20]u8 = undefined;
    @memset(&payload, 0xCC);
    const pkt_slice = buildChunkPacket(&pkt, 100, 1, &payload);
    mock.scriptRecv(pkt_slice);

    var recv_buf: [8]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = mtu });
    try std.testing.expectError(error.BufferTooSmall, wx.run());
}

test "WriteX: total mismatch between chunks" {
    const mtu: u16 = 50;

    var mock = MockTransport{};

    var payload1: [10]u8 = undefined;
    @memset(&payload1, 0xAA);
    var pkt1: [xfer.chunk.max_mtu]u8 = undefined;
    const slice1 = buildChunkPacket(&pkt1, 5, 1, &payload1);
    mock.scriptRecv(slice1);

    var payload2: [10]u8 = undefined;
    @memset(&payload2, 0xBB);
    var pkt2: [xfer.chunk.max_mtu]u8 = undefined;
    const slice2 = buildChunkPacket(&pkt2, 10, 2, &payload2);
    mock.scriptRecv(slice2);

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = mtu });
    try std.testing.expectError(error.TotalMismatch, wx.run());
}

test "WriteX: invalid header (seq=0)" {
    var mock = MockTransport{};
    var pkt: [xfer.chunk.max_mtu]u8 = undefined;
    const pkt_slice = buildChunkPacket(&pkt, 5, 0, "data");
    mock.scriptRecv(pkt_slice);

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = 50 });
    try std.testing.expectError(error.InvalidHeader, wx.run());
}

test "WriteX: invalid header (seq > total)" {
    var mock = MockTransport{};
    var pkt: [xfer.chunk.max_mtu]u8 = undefined;
    const pkt_slice = buildChunkPacket(&pkt, 3, 4, "data");
    mock.scriptRecv(pkt_slice);

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = 50 });
    try std.testing.expectError(error.InvalidHeader, wx.run());
}

test "WriteX: timeout before any xfer.chunk then retry succeeds" {
    const mtu: u16 = 50;
    var mock = MockTransport{};

    mock.scriptTimeout();

    var pkt: [xfer.chunk.max_mtu]u8 = undefined;
    const pkt_slice = buildChunkPacket(&pkt, 1, 1, "hello");
    mock.scriptRecv(pkt_slice);

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = mtu, .max_retries = 3 });
    const result = try wx.run();

    try std.testing.expectEqualSlices(u8, "hello", result.data);
}

test "WriteX: data exactly fills xfer.chunk boundary" {
    const mtu: u16 = 30;
    const dcs = comptime xfer.chunk.dataChunkSize(30);
    var data: [dcs * 2]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i % 256);

    var mock = MockTransport{};
    var i: u16 = 0;
    while (i < 2) : (i += 1) {
        var pkt: [xfer.chunk.max_mtu]u8 = undefined;
        const offset: usize = @as(usize, i) * dcs;
        const pkt_slice = buildChunkPacket(&pkt, 2, i + 1, data[offset .. offset + dcs]);
        mock.scriptRecv(pkt_slice);
    }

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = mtu });
    const result = try wx.run();

    try std.testing.expectEqualSlices(u8, &data, result.data);
    try std.testing.expectEqual(data.len, result.data.len);
}

test "WriteX: max_retries=1 fails on first timeout" {
    var mock = MockTransport{};
    mock.scriptTimeout();

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = 50, .max_retries = 1 });
    try std.testing.expectError(error.Timeout, wx.run());
}

// ============================================================================
// End-to-End Tests
// ============================================================================

test "end-to-end: ReadX chunks → WriteX reassembly" {
    const mtu: u16 = 30;
    const data = "The quick brown fox jumps over the lazy dog. 0123456789!";

    var read_mock = MockTransport{};
    read_mock.scriptRecv(&xfer.chunk.start_magic);
    read_mock.scriptRecv(&xfer.chunk.ack_signal);

    var rx = ReadX(MockTransport).init(&read_mock, data, .{
        .mtu = mtu,
        .send_redundancy = 1,
    });
    try rx.run();

    var write_mock = MockTransport{};
    for (0..read_mock.sent_count) |i| {
        const sent = read_mock.getSent(i);
        write_mock.scriptRecv(sent);
    }

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&write_mock, &recv_buf, .{ .mtu = mtu });
    const result = try wx.run();

    try std.testing.expectEqualSlices(u8, data, result.data);
}

test "end-to-end: large data with multiple MTU sizes" {
    var data: [500]u8 = undefined;
    for (&data, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }

    const mtus = [_]u16{ 23, 30, 50, 100, 247 };
    for (mtus) |mtu| {
        var read_mock = MockTransport{};
        read_mock.scriptRecv(&xfer.chunk.start_magic);
        read_mock.scriptRecv(&xfer.chunk.ack_signal);

        var rx = ReadX(MockTransport).init(&read_mock, &data, .{
            .mtu = mtu,
            .send_redundancy = 1,
        });
        try rx.run();

        var write_mock = MockTransport{};
        for (0..read_mock.sent_count) |i| {
            const sent = read_mock.getSent(i);
            write_mock.scriptRecv(sent);
        }

        var recv_buf: [2048]u8 = undefined;
        var wx = WriteX(MockTransport).init(&write_mock, &recv_buf, .{ .mtu = mtu });
        const result = try wx.run();

        try std.testing.expectEqualSlices(u8, &data, result.data);
    }
}

test "end-to-end: single byte" {
    const mtu: u16 = 247;
    var read_mock = MockTransport{};
    read_mock.scriptRecv(&xfer.chunk.start_magic);
    read_mock.scriptRecv(&xfer.chunk.ack_signal);

    var rx = ReadX(MockTransport).init(&read_mock, "A", .{ .mtu = mtu, .send_redundancy = 1 });
    try rx.run();

    var write_mock = MockTransport{};
    for (0..read_mock.sent_count) |i| {
        write_mock.scriptRecv(read_mock.getSent(i));
    }

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&write_mock, &recv_buf, .{ .mtu = mtu });
    const result = try wx.run();

    try std.testing.expectEqualSlices(u8, "A", result.data);
}

test "end-to-end: exact MTU boundary data" {
    const mtu: u16 = 30;
    const dcs = comptime xfer.chunk.dataChunkSize(30);
    var data: [dcs * 3]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i % 256);

    var read_mock = MockTransport{};
    read_mock.scriptRecv(&xfer.chunk.start_magic);
    read_mock.scriptRecv(&xfer.chunk.ack_signal);

    var rx = ReadX(MockTransport).init(&read_mock, &data, .{ .mtu = mtu, .send_redundancy = 1 });
    try rx.run();

    try std.testing.expectEqual(@as(usize, 3), read_mock.sent_count);

    var write_mock = MockTransport{};
    for (0..read_mock.sent_count) |i| {
        write_mock.scriptRecv(read_mock.getSent(i));
    }

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&write_mock, &recv_buf, .{ .mtu = mtu });
    const result = try wx.run();

    try std.testing.expectEqualSlices(u8, &data, result.data);
}

test "end-to-end: minimum MTU (7)" {
    const mtu: u16 = 7;
    const data = "Hello!";

    var read_mock = MockTransport{};
    read_mock.scriptRecv(&xfer.chunk.start_magic);
    read_mock.scriptRecv(&xfer.chunk.ack_signal);

    var rx = ReadX(MockTransport).init(&read_mock, data, .{ .mtu = mtu, .send_redundancy = 1 });
    try rx.run();

    var write_mock = MockTransport{};
    for (0..read_mock.sent_count) |i| {
        write_mock.scriptRecv(read_mock.getSent(i));
    }

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&write_mock, &recv_buf, .{ .mtu = mtu });
    const result = try wx.run();

    try std.testing.expectEqualSlices(u8, data, result.data);
}

test "end-to-end: redundancy=2 still reassembles correctly" {
    const mtu: u16 = 30;
    const data = "Redundant transfer test data with some padding!";

    var read_mock = MockTransport{};
    read_mock.scriptRecv(&xfer.chunk.start_magic);
    read_mock.scriptRecv(&xfer.chunk.ack_signal);

    var rx = ReadX(MockTransport).init(&read_mock, data, .{ .mtu = mtu, .send_redundancy = 2 });
    try rx.run();

    const total = xfer.chunk.chunksNeeded(data.len, mtu);
    try std.testing.expectEqual(total * 2, read_mock.sent_count);

    var write_mock = MockTransport{};
    for (0..read_mock.sent_count) |i| {
        write_mock.scriptRecv(read_mock.getSent(i));
    }

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&write_mock, &recv_buf, .{ .mtu = mtu });
    const result = try wx.run();

    try std.testing.expectEqualSlices(u8, data, result.data);
}
