const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const Server = embed.pkg.ble.gatt.server;
const runtime = embed.runtime;
const att = embed.pkg.ble.host.att;

test "GattServer comptime service table" {
    const MyServer = Server.GattServer(runtime.std, &.{
        Server.Service(0x180D, &.{
            Server.Char(0x2A37, .{ .read = true, .notify = true }),
            Server.Char(0x2A38, .{ .read = true }),
        }),
        Server.Service(0xFFE0, &.{
            Server.Char(0xFFE1, .{ .write = true, .notify = true }),
        }),
    });

    try std.testing.expectEqual(@as(usize, 3), MyServer.char_count);
    try std.testing.expectEqual(@as(usize, 10), MyServer.attr_count);
}

test "GattServer handle registration and read dispatch" {
    const MyServer = Server.GattServer(runtime.std, &.{
        Server.Service(0x180D, &.{
            Server.Char(0x2A37, .{ .read = true }),
        }),
    });

    var server = MyServer.init();

    server.handle(0x180D, 0x2A37, struct {
        pub fn serve(req: *Server.Request, w: *Server.ResponseWriter) void {
            _ = req;
            w.write(&[_]u8{ 0x00, 72 });
        }
    }.serve, null);

    const value_handle = MyServer.getValueHandle(0x180D, 0x2A37);

    var req_buf: [3]u8 = undefined;
    req_buf[0] = @intFromEnum(att.att.Opcode.read_request);
    std.mem.writeInt(u16, req_buf[1..3], value_handle, .little);

    var resp_buf: [att.att.MAX_PDU_LEN]u8 = undefined;
    const resp = server.handlePdu(0x0040, &req_buf, &resp_buf) orelse unreachable;

    try std.testing.expectEqual(@as(u8, @intFromEnum(att.att.Opcode.read_response)), resp[0]);
    try std.testing.expectEqual(@as(u8, 0x00), resp[1]);
    try std.testing.expectEqual(@as(u8, 72), resp[2]);
}

test "GattServer write dispatch with handler" {
    const MyServer = Server.GattServer(runtime.std, &.{
        Server.Service(0xFFE0, &.{
            Server.Char(0xFFE1, .{ .write = true }),
        }),
    });

    var server = MyServer.init();

    server.handle(0xFFE0, 0xFFE1, struct {
        pub fn serve(req: *Server.Request, w: *Server.ResponseWriter) void {
            if (req.op == .write) {
                w.ok();
            }
        }
    }.serve, null);

    const value_handle = MyServer.getValueHandle(0xFFE0, 0xFFE1);

    var req_buf: [5]u8 = undefined;
    req_buf[0] = @intFromEnum(att.att.Opcode.write_request);
    std.mem.writeInt(u16, req_buf[1..3], value_handle, .little);
    req_buf[3] = 0xAA;
    req_buf[4] = 0xBB;

    var resp_buf: [att.att.MAX_PDU_LEN]u8 = undefined;
    const resp = server.handlePdu(0x0040, &req_buf, &resp_buf) orelse unreachable;

    try std.testing.expectEqual(@as(u8, @intFromEnum(att.att.Opcode.write_response)), resp[0]);
}

test "GattServer MTU exchange" {
    const MyServer = Server.GattServer(runtime.std, &.{
        Server.Service(0x180D, &.{
            Server.Char(0x2A37, .{ .read = true }),
        }),
    });

    var server = MyServer.init();

    var req_buf: [3]u8 = undefined;
    req_buf[0] = @intFromEnum(att.att.Opcode.exchange_mtu_request);
    std.mem.writeInt(u16, req_buf[1..3], 512, .little);

    var resp_buf: [att.att.MAX_PDU_LEN]u8 = undefined;
    const resp = server.handlePdu(0x0040, &req_buf, &resp_buf) orelse unreachable;

    try std.testing.expectEqual(@as(u8, @intFromEnum(att.att.Opcode.exchange_mtu_response)), resp[0]);
    try std.testing.expectEqual(@as(u16, 512), server.mtu);
}

test "GattServer service discovery" {
    const MyServer = Server.GattServer(runtime.std, &.{
        Server.Service(0x180D, &.{
            Server.Char(0x2A37, .{ .read = true }),
        }),
        Server.Service(0xFFE0, &.{
            Server.Char(0xFFE1, .{ .write = true }),
        }),
    });

    var server = MyServer.init();

    var req_buf: [7]u8 = undefined;
    req_buf[0] = @intFromEnum(att.att.Opcode.read_by_group_type_request);
    std.mem.writeInt(u16, req_buf[1..3], 0x0001, .little);
    std.mem.writeInt(u16, req_buf[3..5], 0xFFFF, .little);
    std.mem.writeInt(u16, req_buf[5..7], att.att.GATT_PRIMARY_SERVICE_UUID, .little);

    var resp_buf: [att.att.MAX_PDU_LEN]u8 = undefined;
    const resp = server.handlePdu(0x0040, &req_buf, &resp_buf) orelse unreachable;

    try std.testing.expectEqual(@as(u8, @intFromEnum(att.att.Opcode.read_by_group_type_response)), resp[0]);
    try std.testing.expectEqual(@as(u8, 6), resp[1]);
    try std.testing.expect(resp.len >= 8);
}

test "GattServer async handler dispatch - concurrent requests" {
    const MyServer = Server.GattServer(runtime.std, &.{
        Server.Service(0xFFE0, &.{
            Server.Char(0xFFE1, .{ .read = true, .write = true }),
        }),
    });

    var server = MyServer.init();

    const Counter = struct {
        value: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    };

    var counter = Counter{};

    server.handle(0xFFE0, 0xFFE1, struct {
        pub fn serve(req: *Server.Request, w: *Server.ResponseWriter) void {
            const ctr: *Counter = @ptrCast(@alignCast(req.user_ctx));
            std.Thread.sleep(10 * std.time.ns_per_ms);
            _ = ctr.value.fetchAdd(1, .monotonic);
            w.write(&[_]u8{0x42});
        }
    }.serve, @ptrCast(&counter));

    const ResponseTracker = struct {
        count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    };
    var tracker = ResponseTracker{};

    const trackingResponseFn = struct {
        fn send(ctx: ?*anyopaque, conn_handle: u16, data: []const u8) void {
            _ = conn_handle;
            _ = data;
            const t: *ResponseTracker = @ptrCast(@alignCast(ctx));
            _ = t.count.fetchAdd(1, .monotonic);
        }
    }.send;

    server.enableAsync(std.testing.allocator, trackingResponseFn, @ptrCast(&tracker));

    const value_handle = MyServer.getValueHandle(0xFFE0, 0xFFE1);

    const N = 4;
    for (0..N) |_| {
        var req_buf: [3]u8 = undefined;
        req_buf[0] = @intFromEnum(att.att.Opcode.read_request);
        std.mem.writeInt(u16, req_buf[1..3], value_handle, .little);

        var resp_buf: [att.att.MAX_PDU_LEN]u8 = undefined;
        const result = server.handlePdu(0x0040, &req_buf, &resp_buf);

        try std.testing.expectEqual(@as(?[]const u8, null), result);
    }

    // Wait for all handler threads to complete
    std.Thread.sleep(200 * std.time.ns_per_ms);

    try std.testing.expectEqual(@as(u32, N), counter.value.load(.monotonic));
    try std.testing.expectEqual(@as(u32, N), tracker.count.load(.monotonic));
}

test "GattServer async handler fallback on sync mode" {
    const MyServer = Server.GattServer(runtime.std, &.{
        Server.Service(0xFFE0, &.{
            Server.Char(0xFFE1, .{ .read = true }),
        }),
    });

    var server = MyServer.init();

    server.handle(0xFFE0, 0xFFE1, struct {
        pub fn serve(req: *Server.Request, w: *Server.ResponseWriter) void {
            _ = req;
            w.write(&[_]u8{ 0xDE, 0xAD });
        }
    }.serve, null);

    const value_handle = MyServer.getValueHandle(0xFFE0, 0xFFE1);

    var req_buf: [3]u8 = undefined;
    req_buf[0] = @intFromEnum(att.att.Opcode.read_request);
    std.mem.writeInt(u16, req_buf[1..3], value_handle, .little);

    var resp_buf: [att.att.MAX_PDU_LEN]u8 = undefined;
    const result = server.handlePdu(0x0040, &req_buf, &resp_buf);

    try std.testing.expect(result != null);
    const resp = result.?;
    try std.testing.expectEqual(@as(u8, @intFromEnum(att.att.Opcode.read_response)), resp[0]);
    try std.testing.expectEqual(@as(u8, 0xDE), resp[1]);
    try std.testing.expectEqual(@as(u8, 0xAD), resp[2]);
}

test "GattServer async write handler receives data" {
    const MyServer = Server.GattServer(runtime.std, &.{
        Server.Service(0xFFE0, &.{
            Server.Char(0xFFE1, .{ .write = true }),
        }),
    });

    var server = MyServer.init();

    const Capture = struct {
        data: [4]u8 = undefined,
        len: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    };
    var capture = Capture{};

    server.handle(0xFFE0, 0xFFE1, struct {
        pub fn serve(req: *Server.Request, w: *Server.ResponseWriter) void {
            const cap: *Capture = @ptrCast(@alignCast(req.user_ctx));
            @memcpy(cap.data[0..req.data.len], req.data);
            _ = cap.len.fetchAdd(@intCast(req.data.len), .monotonic);
            w.ok();
        }
    }.serve, @ptrCast(&capture));

    const ResponseSink = struct {
        fn send(_: ?*anyopaque, _: u16, _: []const u8) void {}
    };

    server.enableAsync(std.testing.allocator, ResponseSink.send, null);

    const value_handle = MyServer.getValueHandle(0xFFE0, 0xFFE1);

    var req_buf: [5]u8 = undefined;
    req_buf[0] = @intFromEnum(att.att.Opcode.write_request);
    std.mem.writeInt(u16, req_buf[1..3], value_handle, .little);
    req_buf[3] = 0xCA;
    req_buf[4] = 0xFE;

    var resp_buf: [att.att.MAX_PDU_LEN]u8 = undefined;
    const result = server.handlePdu(0x0040, &req_buf, &resp_buf);
    try std.testing.expectEqual(@as(?[]const u8, null), result);

    std.Thread.sleep(100 * std.time.ns_per_ms);

    try std.testing.expectEqual(@as(u32, 2), capture.len.load(.monotonic));
    try std.testing.expectEqual(@as(u8, 0xCA), capture.data[0]);
    try std.testing.expectEqual(@as(u8, 0xFE), capture.data[1]);
}
