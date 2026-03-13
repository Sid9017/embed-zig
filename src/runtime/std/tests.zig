const std = @import("std");

const time = @import("time.zig");
const rng = @import("rng.zig");
const sync = @import("sync.zig");
const thread = @import("thread.zig");
const system = @import("system.zig");
const fs = @import("fs.zig");
const socket = @import("socket.zig");
const netif = @import("netif.zig");
const ota_backend = @import("ota_backend.zig");
const channel_test = @import("channel_test.zig");
const select_test = @import("select_test.zig");
const runtime = struct {
    pub const ota_backend = @import("../ota_backend.zig");
};

const std_time: time.Time = .{};
const std_rng: rng.Rng = .{};
const std_system: system.System = .{};
const std_netif: netif.NetIf = .{};

var unique_counter = std.atomic.Value(u64).init(0);

fn makeTmpPath(comptime tag: []const u8, comptime suffix: []const u8, buf: []u8) []const u8 {
    const id = unique_counter.fetchAdd(1, .seq_cst);
    return std.fmt.bufPrint(buf, "/tmp/embed_zig_runtime_{s}_{d}_{d}{s}", .{ tag, std_time.nowMs(), id, suffix }) catch unreachable;
}

fn markDone(ctx: ?*anyopaque) void {
    const value: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
    _ = value.fetchAdd(1, .seq_cst);
}

fn notifyAfterDelay(ctx: ?*anyopaque) void {
    const n: *sync.Notify = @ptrCast(@alignCast(ctx.?));
    std_time.sleepMs(20);
    n.signal();
}

fn tcpServerEcho(ctx: ?*anyopaque) void {
    const Ctx = struct {
        server: *socket.Socket,
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

test "std time nowMs returns positive value" {
    const now = std_time.nowMs();
    try std.testing.expect(now > 0);
}

test "std thread spawn/join executes task" {
    var counter = std.atomic.Value(u32).init(0);
    var th = try thread.Thread.spawn(.{}, markDone, @ptrCast(&counter));
    th.join();
    try std.testing.expectEqual(@as(u32, 1), counter.load(.seq_cst));
}

test "std condition wait/signal works" {
    const Ctx = struct {
        mutex: sync.Mutex,
        cond: sync.Condition,
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

    var ctx = Ctx{ .mutex = sync.Mutex.init(), .cond = sync.Condition.init(), .ready = false };
    defer ctx.cond.deinit();
    defer ctx.mutex.deinit();

    var th = try thread.Thread.spawn(.{}, waiter.run, @ptrCast(&ctx));
    std_time.sleepMs(10);

    ctx.mutex.lock();
    ctx.ready = true;
    ctx.cond.signal();
    ctx.mutex.unlock();

    th.join();
    try std.testing.expect(ctx.ready);
}

test "std notify timedWait" {
    var notify = sync.Notify.init();
    defer notify.deinit();

    var th = try thread.Thread.spawn(.{}, notifyAfterDelay, @ptrCast(&notify));

    const early = notify.timedWait(5 * std.time.ns_per_ms);
    try std.testing.expect(!early);

    const later = notify.timedWait(300 * std.time.ns_per_ms);
    try std.testing.expect(later);

    th.join();
}

test "std rng fills bytes" {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    try std_rng.fill(&a);
    try std_rng.fill(&b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "std system getCpuCount" {
    const cpu = try std_system.getCpuCount();
    try std.testing.expect(cpu >= 1);
}

test "std fs read/write roundtrip" {
    var fs_impl = fs.Fs{};

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

test "std socket tcp loopback echo" {
    var server = try socket.Socket.tcp();
    defer server.close();

    try server.bind(.{ 127, 0, 0, 1 }, 0);
    const port = try server.getBoundPort();
    try server.listen();

    var ok = std.atomic.Value(u32).init(0);
    const Ctx = struct {
        server: *socket.Socket,
        ok: *std.atomic.Value(u32),
    };
    var ctx = Ctx{ .server = &server, .ok = &ok };

    var th = try thread.Thread.spawn(.{}, tcpServerEcho, @ptrCast(&ctx));

    var client = try socket.Socket.tcp();
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
    var server = try socket.Socket.udp();
    defer server.close();
    server.setRecvTimeout(1000);
    server.setSendTimeout(1000);

    try server.bind(.{ 127, 0, 0, 1 }, 0);
    const server_port = try server.getBoundPort();

    var client = try socket.Socket.udp();
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
    const names = std_netif.list();
    try std.testing.expect(names.len >= 1);

    const maybe_info = std_netif.get(names[0]);
    try std.testing.expect(maybe_info != null);

    std_netif.setDefault(names[0]);
    const def = std_netif.getDefault().?;
    try std.testing.expect(std.mem.eql(u8, &def, &names[0]));

    std_netif.setDns(.{ 9, 9, 9, 9 }, .{ 8, 8, 4, 4 });
    const dns = std_netif.getDns();
    try std.testing.expectEqual(@as(u8, 9), dns.primary[0]);
    try std.testing.expectEqual(@as(u8, 8), dns.secondary[0]);
}

test "std ota backend begin/write/finalize" {
    var stage_buf: [256]u8 = undefined;
    var final_buf: [256]u8 = undefined;
    var confirm_buf: [256]u8 = undefined;

    const stage_path = makeTmpPath("ota_stage", ".bin", &stage_buf);
    const final_path = makeTmpPath("ota_final", ".bin", &final_buf);
    const confirm_path = makeTmpPath("ota_confirm", "", &confirm_buf);
    defer std.fs.deleteFileAbsolute(stage_path) catch {};
    defer std.fs.deleteFileAbsolute(final_path) catch {};
    defer std.fs.deleteFileAbsolute(confirm_path) catch {};

    var ota = try ota_backend.OtaBackend.init();
    ota.stage_path = stage_path;
    ota.final_path = final_path;
    ota.confirm_path = confirm_path;

    try std.testing.expectEqual(runtime.ota_backend.State.unknown, ota.getState());

    try ota.begin(4);
    try ota.write("test");
    try ota.finalize();

    try std.testing.expectEqual(runtime.ota_backend.State.pending_verify, ota.getState());

    try ota.confirm();
    try std.testing.expectEqual(runtime.ota_backend.State.valid, ota.getState());

    var file = try std.fs.openFileAbsolute(final_path, .{ .mode = .read_only });
    defer file.close();
    var data: [8]u8 = undefined;
    const n = try file.read(&data);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("test", data[0..n]);
}

test "std ota backend rollback removes image" {
    var stage_buf: [256]u8 = undefined;
    var final_buf: [256]u8 = undefined;
    var confirm_buf: [256]u8 = undefined;

    const stage_path = makeTmpPath("ota_rb_stage", ".bin", &stage_buf);
    const final_path = makeTmpPath("ota_rb_final", ".bin", &final_buf);
    const confirm_path = makeTmpPath("ota_rb_confirm", "", &confirm_buf);
    defer std.fs.deleteFileAbsolute(stage_path) catch {};
    defer std.fs.deleteFileAbsolute(final_path) catch {};
    defer std.fs.deleteFileAbsolute(confirm_path) catch {};

    var ota = try ota_backend.OtaBackend.init();
    ota.stage_path = stage_path;
    ota.final_path = final_path;
    ota.confirm_path = confirm_path;

    try ota.begin(3);
    try ota.write("bad");
    try ota.finalize();

    try std.testing.expectEqual(runtime.ota_backend.State.pending_verify, ota.getState());

    try ota.rollback();
    try std.testing.expectEqual(runtime.ota_backend.State.unknown, ota.getState());
}

test {
    _ = channel_test;
    _ = select_test;
}
