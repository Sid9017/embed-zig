const std = @import("std");
const testing = std.testing;
const module = @import("embed").pkg.net.tls.client;
const Config = module.Config;
const Client = module.Client;
const Error = module.Error;
const connect = module.connect;
const runtime = module.runtime;
const conn_mod = module.conn_mod;
const common = module.common;
const record = module.record;
const handshake = module.handshake;
const ProtocolVersion = module.ProtocolVersion;
const CipherSuite = module.CipherSuite;
const AlertDescription = module.AlertDescription;
const TestMockConn = module.TestMockConn;
const ConcurrentPipeConn = module.ConcurrentPipeConn;

test "Config defaults" {
    const Crypto = runtime.std.Crypto;

    const TestConfig = Config(Crypto);
    const config: TestConfig = .{
        .allocator = std.testing.allocator,
        .hostname = "example.com",
    };

    try std.testing.expectEqual(ProtocolVersion.tls_1_2, config.min_version);
    try std.testing.expectEqual(ProtocolVersion.tls_1_3, config.max_version);
    try std.testing.expectEqual(false, config.skip_verify);
}

test "Client init and deinit" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var conn = TestMockConn{};
    const TestClient = Client(TestMockConn, Crypto, Rng, Mutex);

    var c = try TestClient.init(&conn, .{
        .allocator = std.testing.allocator,
        .hostname = "test.example.com",
    });
    defer c.deinit();

    try std.testing.expect(!c.isConnected());
}

test "Client send before connect returns NotConnected" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var conn = TestMockConn{};
    var c = try Client(TestMockConn, Crypto, Rng, Mutex).init(&conn, .{
        .allocator = std.testing.allocator,
        .hostname = "test.com",
    });
    defer c.deinit();

    try std.testing.expectError(error.NotConnected, c.send("hello"));
}

test "Client recv before connect returns NotConnected" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var conn = TestMockConn{};
    var c = try Client(TestMockConn, Crypto, Rng, Mutex).init(&conn, .{
        .allocator = std.testing.allocator,
        .hostname = "test.com",
    });
    defer c.deinit();

    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.NotConnected, c.recv(&buf));
}

test "Client isConnected reflects state" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var conn = TestMockConn{};
    var c = try Client(TestMockConn, Crypto, Rng, Mutex).init(&conn, .{
        .allocator = std.testing.allocator,
        .hostname = "test.com",
    });
    defer c.deinit();

    try std.testing.expect(!c.isConnected());

    @atomicStore(bool, &c.connected, true, .release);
    try std.testing.expect(c.isConnected());

    @atomicStore(bool, &c.received_close_notify, true, .release);
    try std.testing.expect(!c.isConnected());
}

test "Client close on not-connected is safe" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var conn = TestMockConn{};
    var c = try Client(TestMockConn, Crypto, Rng, Mutex).init(&conn, .{
        .allocator = std.testing.allocator,
        .hostname = "test.com",
    });
    defer c.deinit();

    try c.close();
    try std.testing.expect(!c.isConnected());
}

test "Client getVersion and getCipherSuite defaults" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var conn = TestMockConn{};
    var c = try Client(TestMockConn, Crypto, Rng, Mutex).init(&conn, .{
        .allocator = std.testing.allocator,
        .hostname = "test.com",
    });
    defer c.deinit();

    try std.testing.expectEqual(ProtocolVersion.tls_1_3, c.getVersion());
    try std.testing.expectEqual(CipherSuite.TLS_AES_128_GCM_SHA256, c.getCipherSuite());
}

test "Config custom values" {
    const Crypto = runtime.std.Crypto;

    const config: Config(Crypto) = .{
        .allocator = std.testing.allocator,
        .hostname = "custom.example.com",
        .skip_verify = true,
        .min_version = .tls_1_3,
        .max_version = .tls_1_3,
        .timeout_ms = 5000,
    };

    try std.testing.expectEqual(true, config.skip_verify);
    try std.testing.expectEqual(ProtocolVersion.tls_1_3, config.min_version);
    try std.testing.expectEqual(@as(u32, 5000), config.timeout_ms);
    try std.testing.expectEqualStrings("custom.example.com", config.hostname);
}

test "Client multiple init/deinit cycles" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var conn = TestMockConn{};

    for (0..5) |_| {
        var c = try Client(TestMockConn, Crypto, Rng, Mutex).init(&conn, .{
            .allocator = std.testing.allocator,
            .hostname = "test.com",
        });
        c.deinit();
    }
}

test "Client close sets connected to false" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var conn = TestMockConn{};
    var c = try Client(TestMockConn, Crypto, Rng, Mutex).init(&conn, .{
        .allocator = std.testing.allocator,
        .hostname = "test.com",
    });
    defer c.deinit();

    @atomicStore(bool, &c.connected, true, .release);
    try std.testing.expect(c.isConnected());

    try c.close();
    try std.testing.expect(!c.isConnected());
}

test "concurrent send does not deadlock" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var pipe = ConcurrentPipeConn{};
    var c = try Client(ConcurrentPipeConn, Crypto, Rng, Mutex).init(&pipe, .{
        .allocator = std.testing.allocator,
        .hostname = "concurrent.test",
    });
    defer c.deinit();

    @atomicStore(bool, &c.connected, true, .release);

    const key: [16]u8 = [_]u8{0x80} ** 16;
    const iv: [12]u8 = [_]u8{0x81} ** 12;
    const cipher = try record.CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    c.hs.records.setWriteCipher(cipher);
    c.hs.records.version = .tls_1_3;

    const drain_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: *ConcurrentPipeConn) void {
            var drain_buf: [4096]u8 = undefined;
            for (0..200) |_| {
                _ = p.read(&drain_buf) catch break;
            }
        }
    }.run, .{&pipe});

    var send_errors: [2]bool = .{ false, false };
    const threads: [2]std.Thread = .{
        try std.Thread.spawn(.{}, struct {
            fn run(client: *Client(ConcurrentPipeConn, Crypto, Rng, Mutex), err_flag: *bool) void {
                for (0..50) |_| {
                    _ = client.send("hello from thread A") catch {
                        err_flag.* = true;
                        return;
                    };
                }
            }
        }.run, .{ &c, &send_errors[0] }),
        try std.Thread.spawn(.{}, struct {
            fn run(client: *Client(ConcurrentPipeConn, Crypto, Rng, Mutex), err_flag: *bool) void {
                for (0..50) |_| {
                    _ = client.send("hello from thread B") catch {
                        err_flag.* = true;
                        return;
                    };
                }
            }
        }.run, .{ &c, &send_errors[1] }),
    };

    threads[0].join();
    threads[1].join();
    pipe.close();
    drain_thread.join();
}

test "concurrent recv does not deadlock" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var pipe = ConcurrentPipeConn{};
    var c = try Client(ConcurrentPipeConn, Crypto, Rng, Mutex).init(&pipe, .{
        .allocator = std.testing.allocator,
        .hostname = "concurrent.test",
    });
    defer c.deinit();

    @atomicStore(bool, &c.connected, true, .release);

    const key: [16]u8 = [_]u8{0x90} ** 16;
    const iv: [12]u8 = [_]u8{0x91} ** 12;
    const write_cipher = try record.CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    const read_cipher = try record.CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    c.hs.records.setWriteCipher(write_cipher);
    c.hs.records.version = .tls_1_3;

    const feed_thread = try std.Thread.spawn(.{}, struct {
        fn run(client: *Client(ConcurrentPipeConn, Crypto, Rng, Mutex)) void {
            for (0..20) |_| {
                _ = client.send("feed data for recv") catch break;
            }
        }
    }.run, .{&c});

    c.hs.records.setReadCipher(read_cipher);

    var recv_buf: [256]u8 = undefined;
    var total_recv: usize = 0;
    for (0..20) |_| {
        const n = c.recv(&recv_buf) catch break;
        total_recv += n;
    }

    feed_thread.join();
    try std.testing.expect(total_recv > 0);
}

test "concurrent send and recv do not deadlock" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var pipe = ConcurrentPipeConn{};
    var c = try Client(ConcurrentPipeConn, Crypto, Rng, Mutex).init(&pipe, .{
        .allocator = std.testing.allocator,
        .hostname = "concurrent.test",
    });
    defer c.deinit();

    @atomicStore(bool, &c.connected, true, .release);

    const key: [16]u8 = [_]u8{0xA0} ** 16;
    const iv: [12]u8 = [_]u8{0xA1} ** 12;
    const write_cipher = try record.CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    const read_cipher = try record.CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    c.hs.records.setWriteCipher(write_cipher);
    c.hs.records.setReadCipher(read_cipher);
    c.hs.records.version = .tls_1_3;

    var send_done = std.atomic.Value(bool).init(false);
    var recv_done = std.atomic.Value(bool).init(false);

    const send_thread = try std.Thread.spawn(.{}, struct {
        fn run(client: *Client(ConcurrentPipeConn, Crypto, Rng, Mutex), done: *std.atomic.Value(bool)) void {
            defer done.store(true, .release);
            for (0..10) |_| {
                _ = client.send("concurrent data") catch return;
            }
        }
    }.run, .{ &c, &send_done });

    const recv_thread = try std.Thread.spawn(.{}, struct {
        fn run(client: *Client(ConcurrentPipeConn, Crypto, Rng, Mutex), done: *std.atomic.Value(bool)) void {
            defer done.store(true, .release);
            var buf: [256]u8 = undefined;
            for (0..10) |_| {
                _ = client.recv(&buf) catch return;
            }
        }
    }.run, .{ &c, &recv_done });

    send_thread.join();
    recv_thread.join();

    try std.testing.expect(send_done.load(.acquire));
    try std.testing.expect(recv_done.load(.acquire));
}

test "concurrent close while send does not deadlock" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var pipe = ConcurrentPipeConn{};
    var c = try Client(ConcurrentPipeConn, Crypto, Rng, Mutex).init(&pipe, .{
        .allocator = std.testing.allocator,
        .hostname = "concurrent.test",
    });
    defer c.deinit();

    @atomicStore(bool, &c.connected, true, .release);

    const key: [16]u8 = [_]u8{0xB0} ** 16;
    const iv: [12]u8 = [_]u8{0xB1} ** 12;
    const cipher = try record.CipherState(Crypto).init(.TLS_AES_128_GCM_SHA256, &key, &iv);
    c.hs.records.setWriteCipher(cipher);
    c.hs.records.version = .tls_1_3;

    const drain_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: *ConcurrentPipeConn) void {
            var drain_buf: [4096]u8 = undefined;
            for (0..100) |_| {
                _ = p.read(&drain_buf) catch break;
            }
        }
    }.run, .{&pipe});

    const send_thread = try std.Thread.spawn(.{}, struct {
        fn run(client: *Client(ConcurrentPipeConn, Crypto, Rng, Mutex)) void {
            for (0..20) |_| {
                _ = client.send("data") catch return;
            }
        }
    }.run, .{&c});

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        std.Thread.yield() catch {};
    }
    c.close() catch {};
    pipe.close();

    send_thread.join();
    drain_thread.join();
    try std.testing.expect(!c.isConnected());
}

test "concurrent close_notify sets received flag" {
    const Crypto = runtime.std.Crypto;
    const Rng = runtime.std.Rng;
    const Mutex = runtime.std.Mutex;

    var conn = TestMockConn{};
    var c = try Client(TestMockConn, Crypto, Rng, Mutex).init(&conn, .{
        .allocator = std.testing.allocator,
        .hostname = "test.com",
    });
    defer c.deinit();

    @atomicStore(bool, &c.connected, true, .release);
    @atomicStore(bool, &c.received_close_notify, true, .release);

    try std.testing.expect(!c.isConnected());

    try std.testing.expectError(error.ConnectionClosed, c.send("data"));

    var buf: [64]u8 = undefined;
    const n = try c.recv(&buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "mutex lock/unlock cycle under contention" {
    const Mutex = runtime.std.Mutex;

    var mu = Mutex.init();
    defer mu.deinit();

    var counter: u64 = 0;

    const threads: [4]std.Thread = .{
        try std.Thread.spawn(.{}, struct {
            fn run(m: *Mutex, c: *u64) void {
                for (0..1000) |_| {
                    m.lock();
                    c.* += 1;
                    m.unlock();
                }
            }
        }.run, .{ &mu, &counter }),
        try std.Thread.spawn(.{}, struct {
            fn run(m: *Mutex, c: *u64) void {
                for (0..1000) |_| {
                    m.lock();
                    c.* += 1;
                    m.unlock();
                }
            }
        }.run, .{ &mu, &counter }),
        try std.Thread.spawn(.{}, struct {
            fn run(m: *Mutex, c: *u64) void {
                for (0..1000) |_| {
                    m.lock();
                    c.* += 1;
                    m.unlock();
                }
            }
        }.run, .{ &mu, &counter }),
        try std.Thread.spawn(.{}, struct {
            fn run(m: *Mutex, c: *u64) void {
                for (0..1000) |_| {
                    m.lock();
                    c.* += 1;
                    m.unlock();
                }
            }
        }.run, .{ &mu, &counter }),
    };

    for (&threads) |t| t.join();
    try std.testing.expectEqual(@as(u64, 4000), counter);
}
