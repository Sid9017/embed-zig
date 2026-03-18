const std = @import("std");
const testing = std.testing;
const runtime_std = @import("../../../runtime/std.zig");
const conn_mod = @import("embed").pkg.net.conn;
const record = @import("record.zig");
const common = @import("common.zig");
const client_mod = @import("client.zig");

// ---------------------------------------------------------------------------
// TCP loopback Conn adapter — wraps std.posix TCP socket as a net.Conn
// ---------------------------------------------------------------------------
const TcpConn = struct {
    fd: std.posix.fd_t,
    closed: bool = false,

    pub fn read(self: *TcpConn, buf: []u8) conn_mod.Error!usize {
        if (self.closed) return conn_mod.Error.Closed;
        const n = std.posix.recv(self.fd, buf, 0) catch return conn_mod.Error.ReadFailed;
        if (n == 0) return conn_mod.Error.Closed;
        return n;
    }

    pub fn write(self: *TcpConn, data: []const u8) conn_mod.Error!usize {
        if (self.closed) return conn_mod.Error.Closed;
        return std.posix.send(self.fd, data, 0) catch conn_mod.Error.WriteFailed;
    }

    pub fn close(self: *TcpConn) void {
        if (!self.closed) {
            std.posix.close(self.fd);
            self.closed = true;
        }
    }
};

const TcpPair = struct { client: TcpConn, server: TcpConn, listener_fd: std.posix.fd_t };

fn createTcpPair() !TcpPair {
    const listener = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP) catch
        return error.CreateFailed;
    errdefer std.posix.close(listener);

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    std.posix.bind(listener, &addr.any, addr.getOsSockLen()) catch return error.BindFailed;
    std.posix.listen(listener, 128) catch return error.ListenFailed;

    var bound: std.net.Address = undefined;
    var bound_len: std.posix.socklen_t = @sizeOf(std.net.Address);
    std.posix.getsockname(listener, &bound.any, &bound_len) catch return error.BindFailed;
    const port = bound.getPort();

    const client_fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP) catch
        return error.CreateFailed;
    errdefer std.posix.close(client_fd);

    const connect_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    std.posix.connect(client_fd, &connect_addr.any, connect_addr.getOsSockLen()) catch return error.ConnectFailed;

    var peer: std.net.Address = undefined;
    var peer_len: std.posix.socklen_t = @sizeOf(std.net.Address);
    const server_fd = std.posix.accept(listener, &peer.any, &peer_len, 0) catch return error.AcceptFailed;

    return .{
        .client = .{ .fd = client_fd },
        .server = .{ .fd = server_fd },
        .listener_fd = listener,
    };
}

// ---------------------------------------------------------------------------
// STRESS TEST: RecordLayer over real TCP loopback
// Not linked from test/unit/mod.zig by default. Import this file there, then:
//   cd test/unit && zig build test
// ---------------------------------------------------------------------------
test "stress: RecordLayer over TCP loopback" {
    const Runtime = runtime_std.Std;

    var pair = try createTcpPair();
    defer {
        pair.client.close();
        pair.server.close();
        std.posix.close(pair.listener_fd);
    }

    const key: [16]u8 = [_]u8{0xDE} ** 16;
    const iv: [12]u8 = [_]u8{0xAD} ** 12;

    var client_rl = record.RecordLayer(TcpConn, Runtime).init(&pair.client);
    client_rl.version = .tls_1_3;
    const w_cipher = try record.CipherState(Runtime).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    client_rl.setWriteCipher(w_cipher);

    var server_rl = record.RecordLayer(TcpConn, Runtime).init(&pair.server);
    server_rl.version = .tls_1_3;
    const r_cipher = try record.CipherState(Runtime).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    server_rl.setReadCipher(r_cipher);

    const msg_count = 100;
    const payload = "stress test payload over real TCP loopback";

    const writer_thread = try std.Thread.spawn(.{}, struct {
        fn run(rl: *record.RecordLayer(TcpConn, Runtime)) void {
            var buf: [512]u8 = undefined;
            for (0..msg_count) |_| {
                _ = rl.writeRecord(.application_data, payload, &buf) catch return;
            }
        }
    }.run, .{&client_rl});

    var read_buf: [512]u8 = undefined;
    var pt_out: [512]u8 = undefined;
    var received: usize = 0;
    for (0..msg_count) |_| {
        const result = server_rl.readRecord(&read_buf, &pt_out) catch break;
        if (result.content_type == .application_data) {
            std.testing.expectEqualSlices(u8, payload, pt_out[0..result.length]) catch {};
            received += 1;
        }
    }

    writer_thread.join();
    try std.testing.expectEqual(@as(usize, msg_count), received);
}

test "stress: concurrent TCP record layer writers" {
    const Runtime = runtime_std.Std;

    var pair = try createTcpPair();
    defer {
        pair.client.close();
        pair.server.close();
        std.posix.close(pair.listener_fd);
    }

    const key: [16]u8 = [_]u8{0xCA} ** 16;
    const iv: [12]u8 = [_]u8{0xFE} ** 12;

    var client_rl = record.RecordLayer(TcpConn, Runtime).init(&pair.client);
    client_rl.version = .tls_1_3;
    const w_cipher = try record.CipherState(Runtime).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    client_rl.setWriteCipher(w_cipher);

    var server_rl = record.RecordLayer(TcpConn, Runtime).init(&pair.server);
    server_rl.version = .tls_1_3;
    const r_cipher = try record.CipherState(Runtime).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    server_rl.setReadCipher(r_cipher);

    const msgs_per_thread = 25;
    var mu = std.Thread.Mutex{};

    const writer = struct {
        fn run(rl: *record.RecordLayer(TcpConn, Runtime), m: *std.Thread.Mutex, payload: []const u8) void {
            var buf: [512]u8 = undefined;
            for (0..msgs_per_thread) |_| {
                m.lock();
                _ = rl.writeRecord(.application_data, payload, &buf) catch {
                    m.unlock();
                    return;
                };
                m.unlock();
            }
        }
    };

    const t1 = try std.Thread.spawn(.{}, writer.run, .{ &client_rl, &mu, "thread-1-payload" });
    const t2 = try std.Thread.spawn(.{}, writer.run, .{ &client_rl, &mu, "thread-2-payload" });

    var read_buf: [512]u8 = undefined;
    var pt_out: [512]u8 = undefined;
    var received: usize = 0;
    for (0..msgs_per_thread * 2) |_| {
        const result = server_rl.readRecord(&read_buf, &pt_out) catch break;
        if (result.content_type == .application_data) {
            received += 1;
        }
    }

    t1.join();
    t2.join();
    try std.testing.expectEqual(@as(usize, msgs_per_thread * 2), received);
}

test "stress: multiple TCP pairs simultaneous" {
    const Runtime = runtime_std.Std;

    const pair_count = 4;
    const msgs_per_pair = 20;

    var pairs: [pair_count]TcpPair = undefined;
    var valid_pairs: usize = 0;

    for (0..pair_count) |i| {
        pairs[i] = createTcpPair() catch continue;
        valid_pairs += 1;
    }
    defer {
        for (0..valid_pairs) |i| {
            pairs[i].client.close();
            pairs[i].server.close();
            std.posix.close(pairs[i].listener_fd);
        }
    }

    if (valid_pairs == 0) return;

    var total_received = std.atomic.Value(usize).init(0);

    var threads: [pair_count * 2]?std.Thread = [_]?std.Thread{null} ** (pair_count * 2);
    var client_rls: [pair_count]record.RecordLayer(TcpConn, Runtime) = undefined;
    var server_rls: [pair_count]record.RecordLayer(TcpConn, Runtime) = undefined;

    for (0..valid_pairs) |i| {
        const key: [16]u8 = [_]u8{@intCast(0x10 + i)} ** 16;
        const iv: [12]u8 = [_]u8{@intCast(0x20 + i)} ** 12;

        client_rls[i] = record.RecordLayer(TcpConn, Runtime).init(&pairs[i].client);
        client_rls[i].version = .tls_1_3;
        const wc = record.CipherState(Runtime).init(.TLS_AES_128_GCM_SHA256, &key, &iv) catch continue;
        client_rls[i].setWriteCipher(wc);

        server_rls[i] = record.RecordLayer(TcpConn, Runtime).init(&pairs[i].server);
        server_rls[i].version = .tls_1_3;
        const rc = record.CipherState(Runtime).init(.TLS_AES_128_GCM_SHA256, &key, &iv) catch continue;
        server_rls[i].setReadCipher(rc);

        threads[i * 2] = std.Thread.spawn(.{}, struct {
            fn run(rl: *record.RecordLayer(TcpConn, Runtime)) void {
                var buf: [512]u8 = undefined;
                for (0..msgs_per_pair) |_| {
                    _ = rl.writeRecord(.application_data, "multi-pair-test", &buf) catch return;
                }
            }
        }.run, .{&client_rls[i]}) catch null;

        threads[i * 2 + 1] = std.Thread.spawn(.{}, struct {
            fn run(rl: *record.RecordLayer(TcpConn, Runtime), counter: *std.atomic.Value(usize)) void {
                var read_buf: [512]u8 = undefined;
                var pt_out: [512]u8 = undefined;
                for (0..msgs_per_pair) |_| {
                    const result = rl.readRecord(&read_buf, &pt_out) catch return;
                    if (result.content_type == .application_data) {
                        _ = counter.fetchAdd(1, .monotonic);
                    }
                }
            }
        }.run, .{ &server_rls[i], &total_received }) catch null;
    }

    for (&threads) |*t| {
        if (t.*) |thread| thread.join();
    }

    try std.testing.expect(total_received.load(.acquire) > 0);
}

test "stress: TCP loopback TLS 1.2 encrypted records" {
    const Runtime = runtime_std.Std;

    var pair = try createTcpPair();
    defer {
        pair.client.close();
        pair.server.close();
        std.posix.close(pair.listener_fd);
    }

    const key: [16]u8 = [_]u8{0xBE} ** 16;
    const iv: [12]u8 = [_]u8{0xEF} ** 12;

    var client_rl = record.RecordLayer(TcpConn, Runtime).init(&pair.client);
    client_rl.version = .tls_1_2;
    const w_cipher = try record.CipherState(Runtime).init(.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, &key, &iv);
    client_rl.setWriteCipher(w_cipher);

    var server_rl = record.RecordLayer(TcpConn, Runtime).init(&pair.server);
    server_rl.version = .tls_1_2;
    const r_cipher = try record.CipherState(Runtime).init(.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, &key, &iv);
    server_rl.setReadCipher(r_cipher);

    const msg_count = 50;

    const writer_thread = try std.Thread.spawn(.{}, struct {
        fn run(rl: *record.RecordLayer(TcpConn, Runtime)) void {
            var buf: [512]u8 = undefined;
            for (0..msg_count) |_| {
                _ = rl.writeRecord(.application_data, "tls12 stress", &buf) catch return;
            }
        }
    }.run, .{&client_rl});

    var read_buf: [512]u8 = undefined;
    var pt_out: [512]u8 = undefined;
    var received: usize = 0;
    for (0..msg_count) |_| {
        const result = server_rl.readRecord(&read_buf, &pt_out) catch break;
        if (result.content_type == .application_data) {
            std.testing.expectEqualSlices(u8, "tls12 stress", pt_out[0..result.length]) catch {};
            received += 1;
        }
    }

    writer_thread.join();
    try std.testing.expectEqual(@as(usize, msg_count), received);
}

test "stress: TCP loopback ChaCha20-Poly1305" {
    const Runtime = runtime_std.Std;

    var pair = try createTcpPair();
    defer {
        pair.client.close();
        pair.server.close();
        std.posix.close(pair.listener_fd);
    }

    const key: [32]u8 = [_]u8{0xCC} ** 32;
    const iv: [12]u8 = [_]u8{0xDD} ** 12;

    var client_rl = record.RecordLayer(TcpConn, Runtime).init(&pair.client);
    client_rl.version = .tls_1_3;
    const w_cipher = try record.CipherState(Runtime).init(.TLS_CHACHA20_POLY1305_SHA256, &key, &iv);
    client_rl.setWriteCipher(w_cipher);

    var server_rl = record.RecordLayer(TcpConn, Runtime).init(&pair.server);
    server_rl.version = .tls_1_3;
    const r_cipher = try record.CipherState(Runtime).init(.TLS_CHACHA20_POLY1305_SHA256, &key, &iv);
    server_rl.setReadCipher(r_cipher);

    const msg_count = 50;

    const writer_thread = try std.Thread.spawn(.{}, struct {
        fn run(rl: *record.RecordLayer(TcpConn, Runtime)) void {
            var buf: [512]u8 = undefined;
            for (0..msg_count) |_| {
                _ = rl.writeRecord(.application_data, "chacha stress", &buf) catch return;
            }
        }
    }.run, .{&client_rl});

    var read_buf: [512]u8 = undefined;
    var pt_out: [512]u8 = undefined;
    var received: usize = 0;
    for (0..msg_count) |_| {
        const result = server_rl.readRecord(&read_buf, &pt_out) catch break;
        if (result.content_type == .application_data) {
            std.testing.expectEqualSlices(u8, "chacha stress", pt_out[0..result.length]) catch {};
            received += 1;
        }
    }

    writer_thread.join();
    try std.testing.expectEqual(@as(usize, msg_count), received);
}

test "stress: large payload over TCP" {
    const Runtime = runtime_std.Std;

    var pair = try createTcpPair();
    defer {
        pair.client.close();
        pair.server.close();
        std.posix.close(pair.listener_fd);
    }

    const key: [16]u8 = [_]u8{0xEE} ** 16;
    const iv: [12]u8 = [_]u8{0xFF} ** 12;

    var client_rl = record.RecordLayer(TcpConn, Runtime).init(&pair.client);
    client_rl.version = .tls_1_3;
    const w_cipher = try record.CipherState(Runtime).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    client_rl.setWriteCipher(w_cipher);

    var server_rl = record.RecordLayer(TcpConn, Runtime).init(&pair.server);
    server_rl.version = .tls_1_3;
    const r_cipher = try record.CipherState(Runtime).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    server_rl.setReadCipher(r_cipher);

    var large_payload: [8192]u8 = undefined;
    for (&large_payload, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    var write_buf: [common.MAX_CIPHERTEXT_LEN + 256]u8 = undefined;
    const writer_thread = try std.Thread.spawn(.{}, struct {
        fn run(rl: *record.RecordLayer(TcpConn, Runtime), payload: []const u8, buf: []u8) void {
            for (0..10) |_| {
                _ = rl.writeRecord(.application_data, payload, buf) catch return;
            }
        }
    }.run, .{ &client_rl, &large_payload, &write_buf });

    var read_buf: [common.MAX_CIPHERTEXT_LEN + 256]u8 = undefined;
    var pt_out: [common.MAX_CIPHERTEXT_LEN]u8 = undefined;
    var received: usize = 0;
    for (0..10) |_| {
        const result = server_rl.readRecord(&read_buf, &pt_out) catch break;
        if (result.content_type == .application_data and result.length == large_payload.len) {
            std.testing.expectEqualSlices(u8, &large_payload, pt_out[0..result.length]) catch {};
            received += 1;
        }
    }

    writer_thread.join();
    try std.testing.expectEqual(@as(usize, 10), received);
}
