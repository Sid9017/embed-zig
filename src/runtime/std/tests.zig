const std = @import("std");

const time = @import("time.zig");
const rng = @import("rng.zig");
const sync = @import("sync.zig");
const thread = @import("thread.zig");
const system = @import("system.zig");
const fs = @import("fs.zig");
const io = @import("io.zig");
const socket = @import("socket.zig");
const netif = @import("netif.zig");
const ota_backend = @import("ota_backend.zig");
const root = @import("root.zig");

var unique_counter = std.atomic.Value(u64).init(0);

fn makeTmpPath(comptime tag: []const u8, comptime suffix: []const u8, buf: []u8) []const u8 {
    const id = unique_counter.fetchAdd(1, .seq_cst);
    return std.fmt.bufPrint(buf, "/tmp/embed_zig_runtime_{s}_{d}_{d}{s}", .{ tag, time.StdTime.nowMs(), id, suffix }) catch unreachable;
}

fn markDone(ctx: ?*anyopaque) void {
    const value: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
    _ = value.fetchAdd(1, .seq_cst);
}

fn notifyAfterDelay(ctx: ?*anyopaque) void {
    const n: *sync.StdNotify = @ptrCast(@alignCast(ctx.?));
    time.StdTime.sleepMs(20);
    n.signal();
}

fn ioReadReady(ctx: ?*anyopaque, fd: std.posix.fd_t) void {
    const called: *u32 = @ptrCast(@alignCast(ctx.?));
    var buf: [32]u8 = undefined;
    _ = std.posix.read(fd, &buf) catch {};
    called.* += 1;
}

fn tcpServerEcho(ctx: ?*anyopaque) void {
    const Ctx = struct {
        server: *socket.StdSocket,
        ok: *std.atomic.Value(u32),
    };

    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    var accepted = c.server.accept() catch return;
    defer accepted.close();

    accepted.setRecvTimeout(1000);
    accepted.setSendTimeout(1000);

    var buf: [64]u8 = undefined;
    const n = accepted.recv(&buf) catch return;
    _ = accepted.send(buf[0..n]) catch return;
    _ = c.ok.fetchAdd(1, .seq_cst);
}

test "std runtime evented profile validate" {
    _ = root.StdRuntime;
}

test "std thread spawn/join executes task" {
    var counter = std.atomic.Value(u32).init(0);
    var th = try thread.StdThread.spawn(.{}, markDone, @ptrCast(&counter));
    th.join();
    try std.testing.expectEqual(@as(u32, 1), counter.load(.seq_cst));
}

test "std condition wait/signal works" {
    const Ctx = struct {
        mutex: sync.StdMutex,
        cond: sync.StdCondition,
        ready: bool,
    };

    const waiter = struct {
        fn run(ptr: ?*anyopaque) void {
            const ctx: *Ctx = @ptrCast(@alignCast(ptr.?));
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            while (!ctx.ready) {
                ctx.cond.wait(&ctx.mutex);
            }
        }
    };

    var ctx = Ctx{ .mutex = sync.StdMutex.init(), .cond = sync.StdCondition.init(), .ready = false };
    defer ctx.cond.deinit();
    defer ctx.mutex.deinit();

    var th = try thread.StdThread.spawn(.{}, waiter.run, @ptrCast(&ctx));
    time.StdTime.sleepMs(10);

    ctx.mutex.lock();
    ctx.ready = true;
    ctx.cond.signal();
    ctx.mutex.unlock();

    th.join();
    try std.testing.expect(ctx.ready);
}

test "std notify timedWait" {
    var notify = sync.StdNotify.init();
    defer notify.deinit();

    var th = try thread.StdThread.spawn(.{}, notifyAfterDelay, @ptrCast(&notify));

    const early = notify.timedWait(5 * std.time.ns_per_ms);
    try std.testing.expect(!early);

    const later = notify.timedWait(300 * std.time.ns_per_ms);
    try std.testing.expect(later);

    th.join();
}

test "std rng fills bytes" {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    try rng.StdRng.fill(&a);
    try rng.StdRng.fill(&b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "std system getCpuCount" {
    const cpu = try system.StdSystem.getCpuCount();
    try std.testing.expect(cpu >= 1);
}

test "std fs read/write roundtrip" {
    var fs_impl = fs.StdFs{};

    var path_buf: [256]u8 = undefined;
    const path = makeTmpPath("fs", ".bin", &path_buf);
    defer std.fs.deleteFileAbsolute(path) catch {};

    var out = fs_impl.open(path, .write) orelse return error.TestUnexpectedResult;
    defer out.close();
    const wrote = try out.write("hello-std-runtime");
    try std.testing.expectEqual(@as(usize, "hello-std-runtime".len), wrote);

    var in = fs_impl.open(path, .read) orelse return error.TestUnexpectedResult;
    defer in.close();
    var buf: [64]u8 = undefined;
    const got = try in.readAll(&buf);
    try std.testing.expectEqualStrings("hello-std-runtime", got);
}

test "std io registerRead and poll" {
    var io_impl = try io.StdIO.init(std.testing.allocator);
    defer io_impl.deinit();

    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    defer std.posix.close(p[1]);

    var called: u32 = 0;
    try io_impl.registerRead(p[0], .{ .ptr = @ptrCast(&called), .callback = &ioReadReady });

    const msg = [_]u8{'x'};
    _ = try std.posix.write(p[1], &msg);

    const fired = io_impl.poll(1000);
    try std.testing.expect(fired >= 1);
    try std.testing.expectEqual(@as(u32, 1), called);

    io_impl.unregister(p[0]);
}

test "std io wake drains buffered wake bytes" {
    var io_impl = try io.StdIO.init(std.testing.allocator);
    defer io_impl.deinit();

    var i: usize = 0;
    while (i < 8192) : (i += 1) {
        io_impl.wake();
    }

    _ = io_impl.poll(10);
    const second = io_impl.poll(0);
    try std.testing.expectEqual(@as(usize, 0), second);
}

test "std socket tcp loopback echo" {
    var server = try socket.StdSocket.tcp();
    defer server.close();

    try server.bind(.{ 127, 0, 0, 1 }, 0);
    const port = try server.getBoundPort();
    try server.listen();

    var ok = std.atomic.Value(u32).init(0);
    const Ctx = struct {
        server: *socket.StdSocket,
        ok: *std.atomic.Value(u32),
    };
    var ctx = Ctx{ .server = &server, .ok = &ok };

    var th = try thread.StdThread.spawn(.{}, tcpServerEcho, @ptrCast(&ctx));

    var client = try socket.StdSocket.tcp();
    defer client.close();
    client.setRecvTimeout(1000);
    client.setSendTimeout(1000);

    try client.connect(.{ 127, 0, 0, 1 }, port);
    _ = try client.send("ping");

    var buf: [16]u8 = undefined;
    const n = try client.recv(&buf);
    try std.testing.expectEqualStrings("ping", buf[0..n]);

    th.join();
    try std.testing.expectEqual(@as(u32, 1), ok.load(.seq_cst));
}

test "std socket udp recvFrom/sendTo" {
    var server = try socket.StdSocket.udp();
    defer server.close();
    server.setRecvTimeout(1000);
    server.setSendTimeout(1000);

    try server.bind(.{ 127, 0, 0, 1 }, 0);
    const server_port = try server.getBoundPort();

    var client = try socket.StdSocket.udp();
    defer client.close();
    client.setRecvTimeout(1000);
    client.setSendTimeout(1000);

    _ = try client.sendTo(.{ 127, 0, 0, 1 }, server_port, "u");

    var recv_buf: [16]u8 = undefined;
    const from = try server.recvFrom(&recv_buf);
    try std.testing.expectEqual(@as(usize, 1), from.len);
    try std.testing.expectEqual(@as(u8, 'u'), recv_buf[0]);

    _ = try server.sendTo(from.src_addr, from.src_port, "ok");

    var client_buf: [16]u8 = undefined;
    const from2 = try client.recvFrom(&client_buf);
    try std.testing.expectEqual(@as(usize, 2), from2.len);
    try std.testing.expectEqualStrings("ok", client_buf[0..2]);
}

test "std netif dns and default interface" {
    const names = netif.StdNetIf.list();
    try std.testing.expect(names.len >= 1);

    const maybe_info = netif.StdNetIf.get(names[0]);
    try std.testing.expect(maybe_info != null);

    netif.StdNetIf.setDefault(names[0]);
    const def = netif.StdNetIf.getDefault().?;
    try std.testing.expect(std.mem.eql(u8, &def, &names[0]));

    netif.StdNetIf.setDns(.{ 9, 9, 9, 9 }, .{ 8, 8, 4, 4 });
    const dns = netif.StdNetIf.getDns();
    try std.testing.expectEqual(@as(u8, 9), dns.primary[0]);
    try std.testing.expectEqual(@as(u8, 8), dns.secondary[0]);
}

test "std ota backend begin/write/finalize" {
    var stage_buf: [256]u8 = undefined;
    var final_buf: [256]u8 = undefined;

    const stage_path = makeTmpPath("ota_stage", ".bin", &stage_buf);
    const final_path = makeTmpPath("ota_final", ".bin", &final_buf);
    defer std.fs.deleteFileAbsolute(stage_path) catch {};
    defer std.fs.deleteFileAbsolute(final_path) catch {};

    var ota = try ota_backend.StdOtaBackend.init();
    ota.stage_path = stage_path;
    ota.final_path = final_path;

    try ota.begin(4);
    try ota.write("test");
    try ota.finalize();

    var file = try std.fs.openFileAbsolute(final_path, .{ .mode = .read_only });
    defer file.close();
    var data: [8]u8 = undefined;
    const n = try file.read(&data);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("test", data[0..n]);
}
