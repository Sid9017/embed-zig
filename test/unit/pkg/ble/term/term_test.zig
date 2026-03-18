const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const term = embed.pkg.ble.term;
const ble = embed.pkg.ble;

const shell_mod = embed.pkg.ble.term.shell;
const Shell = shell_mod.Shell;
const CancellationToken = shell_mod.CancellationToken;
const ResponseWriter = shell_mod.ResponseWriter;
const parseRequest = shell_mod.parseRequest;
const encodeResponse = shell_mod.encodeResponse;

// ============================================================================
// MockTransport for end-to-end tests
// ============================================================================

const MockTransport = struct {
    const max_sent_data: usize = 32768;
    const max_sent_entries: usize = 512;
    const max_recv_entries: usize = 128;
    const max_recv_data: usize = 16384;

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

    fn getSent(self: *const MockTransport, idx: usize) []const u8 {
        var offset: usize = 0;
        for (self.sent_lens[0..idx]) |l| {
            offset += l;
        }
        return self.sent_data[offset .. offset + self.sent_lens[idx]];
    }
};

// ============================================================================
// Shell integration tests
// ============================================================================

test "Shell: full request/response cycle" {
    const handler = struct {
        pub fn serve(req: *const shell_mod.Request, w: *ResponseWriter) void {
            w.print("hello from {s}", .{req.cmd});
        }
    }.serve;

    var shell = Shell.init();
    try shell.register("greet", handler, null);

    var cancel = CancellationToken{};
    var resp_buf: [256]u8 = undefined;
    const writer = shell.dispatch("greet", "", 1, 0x40, &cancel, &resp_buf);

    var json_buf: [512]u8 = undefined;
    const json = encodeResponse(&json_buf, 1, writer.output(), writer.err_msg, writer.exit_code);

    // Verify it's valid JSON-ish
    try std.testing.expect(json.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "hello from greet") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"exit\":0") != null);
}

test "Shell: handler checks cancellation" {
    const handler = struct {
        pub fn serve(req: *const shell_mod.Request, w: *ResponseWriter) void {
            if (req.cancel.isCancelled()) {
                w.setError(-1, "cancelled");
                return;
            }
            w.write("done");
        }
    }.serve;

    var shell = Shell.init();
    try shell.register("slow", handler, null);

    // Not cancelled
    {
        var cancel = CancellationToken{};
        var resp_buf: [256]u8 = undefined;
        const writer = shell.dispatch("slow", "", 1, 0x40, &cancel, &resp_buf);
        try std.testing.expectEqualSlices(u8, "done", writer.output());
    }

    // Cancelled
    {
        var cancel = CancellationToken{};
        cancel.cancel();
        var resp_buf: [256]u8 = undefined;
        const writer = shell.dispatch("slow", "", 2, 0x40, &cancel, &resp_buf);
        try std.testing.expectEqual(@as(i8, -1), writer.exit_code);
        try std.testing.expectEqualSlices(u8, "cancelled", writer.err_msg);
    }
}

test "Shell: multiple commands registered" {
    const echo_handler = struct {
        pub fn serve(req: *const shell_mod.Request, w: *ResponseWriter) void {
            w.write(req.args);
        }
    }.serve;

    const info_handler = struct {
        pub fn serve(_: *const shell_mod.Request, w: *ResponseWriter) void {
            w.write("v1.0");
        }
    }.serve;

    var shell = Shell.init();
    try shell.register("echo", echo_handler, null);
    try shell.register("sys.info", info_handler, null);

    var cancel = CancellationToken{};

    {
        var resp_buf: [256]u8 = undefined;
        const w = shell.dispatch("echo", "hello world", 1, 0x40, &cancel, &resp_buf);
        try std.testing.expectEqualSlices(u8, "hello world", w.output());
    }

    {
        var resp_buf: [256]u8 = undefined;
        const w = shell.dispatch("sys.info", "", 2, 0x40, &cancel, &resp_buf);
        try std.testing.expectEqualSlices(u8, "v1.0", w.output());
    }
}

// ============================================================================
// JSON roundtrip tests
// ============================================================================

test "JSON: parse and encode roundtrip" {
    const input = "{\"cmd\":\"echo hello\",\"id\":7}";
    const parsed = parseRequest(input) orelse unreachable;
    try std.testing.expectEqualSlices(u8, "echo", parsed.cmd);
    try std.testing.expectEqualSlices(u8, "hello", parsed.args);
    try std.testing.expectEqual(@as(u32, 7), parsed.id);

    var buf: [256]u8 = undefined;
    const resp = encodeResponse(&buf, 7, "hello", "", 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"out\":\"hello\"") != null);
}

test "JSON: special characters escaped" {
    var buf: [256]u8 = undefined;
    const resp = encodeResponse(&buf, 1, "line1\nline2\ttab", "err\"quote", 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "line1\\nline2\\ttab") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "err\\\"quote") != null);
}

// ============================================================================
// ble.xfer end-to-end: simulate CLI sending command, firmware responding
// ============================================================================

test "xfer roundtrip: WRITE_X command then READ_X response" {
    const mtu: u16 = 50;
    const cmd_json = "{\"cmd\":\"echo hi\",\"id\":1}";

    // Step 1: Simulate CLI sending command via WRITE_X (ReadX on CLI side)
    var cli_write_mock = MockTransport{};
    cli_write_mock.scriptRecv(&ble.xfer.start_magic);
    cli_write_mock.scriptRecv(&ble.xfer.ack_signal);

    var cli_rx = ble.xfer.ReadX(MockTransport).init(&cli_write_mock, cmd_json, .{
        .mtu = mtu,
        .send_redundancy = 1,
    });
    try cli_rx.run();

    // Step 2: Firmware receives via WriteX
    var fw_recv_mock = MockTransport{};
    for (0..cli_write_mock.sent_count) |i| {
        fw_recv_mock.scriptRecv(cli_write_mock.getSent(i));
    }

    var recv_buf: [2048]u8 = undefined;
    var fw_wx = ble.xfer.WriteX(MockTransport).init(&fw_recv_mock, &recv_buf, .{ .mtu = mtu });
    const result = try fw_wx.run();

    try std.testing.expectEqualSlices(u8, cmd_json, result.data);

    // Step 3: Parse and execute
    const parsed = parseRequest(result.data) orelse unreachable;
    var shell = Shell.init();
    const echo_handler = struct {
        pub fn serve(req: *const shell_mod.Request, w: *ResponseWriter) void {
            w.write(req.args);
        }
    }.serve;
    try shell.register("echo", echo_handler, null);

    var cancel = CancellationToken{};
    var resp_buf: [256]u8 = undefined;
    const writer = shell.dispatch(parsed.cmd, parsed.args, parsed.id, 0x40, &cancel, &resp_buf);

    var json_buf: [512]u8 = undefined;
    const resp_json = encodeResponse(&json_buf, parsed.id, writer.output(), writer.err_msg, writer.exit_code);

    // Step 4: Firmware sends response via READ_X
    var fw_send_mock = MockTransport{};
    fw_send_mock.scriptRecv(&ble.xfer.start_magic);
    fw_send_mock.scriptRecv(&ble.xfer.ack_signal);

    var fw_rx = ble.xfer.ReadX(MockTransport).init(&fw_send_mock, resp_json, .{
        .mtu = mtu,
        .send_redundancy = 1,
    });
    try fw_rx.run();

    // Step 5: CLI receives response via WriteX
    var cli_recv_mock = MockTransport{};
    for (0..fw_send_mock.sent_count) |i| {
        cli_recv_mock.scriptRecv(fw_send_mock.getSent(i));
    }

    var cli_recv_buf: [2048]u8 = undefined;
    var cli_wx = ble.xfer.WriteX(MockTransport).init(&cli_recv_mock, &cli_recv_buf, .{ .mtu = mtu });
    const cli_result = try cli_wx.run();

    // Verify final response
    try std.testing.expectEqualSlices(u8, resp_json, cli_result.data);
    try std.testing.expect(std.mem.indexOf(u8, cli_result.data, "\"out\":\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cli_result.data, "\"exit\":0") != null);
}
