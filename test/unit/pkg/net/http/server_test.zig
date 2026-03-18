const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const mem = std.mem;
const server_mod = embed.pkg.net.http.server_mod;
const request_mod = embed.pkg.net.http.request;
const response_mod = embed.pkg.net.http.response;
const router_mod = embed.pkg.net.http.router;
const Std = embed.runtime.std;

const Request = request_mod.Request;
const Response = response_mod.Response;
const Route = router_mod.Route;
const Socket = Std.Socket;

const MockConn = struct {
    state: *State,

    const State = struct {
        input: []const u8,
        input_pos: usize = 0,
        output: [8192]u8 = undefined,
        output_len: usize = 0,
        closed: bool = false,
    };

    pub fn recv(self: *MockConn, buf: []u8) !usize {
        const s = self.state;
        if (s.input_pos >= s.input.len) return 0;
        const remaining = s.input[s.input_pos..];
        const n = @min(remaining.len, buf.len);
        @memcpy(buf[0..n], remaining[0..n]);
        s.input_pos += n;
        return n;
    }

    pub fn send(self: *MockConn, data: []const u8) !usize {
        const s = self.state;
        const end = s.output_len + data.len;
        if (end > s.output.len) return error.SendFailed;
        @memcpy(s.output[s.output_len..end], data);
        s.output_len = end;
        return data.len;
    }

    pub fn close(self: *MockConn) void {
        self.state.closed = true;
    }
};

fn testHandler(_: *Request, resp: *Response) void {
    _ = resp.contentType("text/plain");
    resp.send("Hello");
}

const SocketConn = struct {
    sock: Socket,

    pub const ConnError = error{ Timeout, Closed };

    pub fn recv(self: *SocketConn, buf: []u8) ConnError!usize {
        return self.sock.recv(buf) catch |e| switch (e) {
            error.Timeout => error.Timeout,
            error.Closed => error.Closed,
            else => error.Closed,
        };
    }

    pub fn send(self: *SocketConn, data: []const u8) ConnError!usize {
        return self.sock.send(data) catch |e| switch (e) {
            error.Timeout => error.Timeout,
            else => error.Closed,
        };
    }

    pub fn close(self: *SocketConn) void {
        self.sock.close();
    }
};

fn echoHandler(req: *Request, resp: *Response) void {
    _ = resp.contentType("text/plain");
    if (req.body) |b| {
        resp.send(b);
    } else {
        resp.send(req.path);
    }
}

fn jsonHandler(_: *Request, resp: *Response) void {
    resp.json("{\"ok\":true}");
}

fn slowHandler(_: *Request, resp: *Response) void {
    std.Thread.sleep(10 * std.time.ns_per_ms);
    resp.send("slow");
}

const test_routes = [_]Route{
    router_mod.get("/echo", echoHandler),
    router_mod.get("/json", jsonHandler),
    router_mod.post("/echo", echoHandler),
    router_mod.get("/slow", slowHandler),
};

fn startTestServer(port_out: *u16) !Socket {
    var listener = try Socket.tcp();
    try listener.bind(.{ 127, 0, 0, 1 }, 0);
    try listener.listen();
    port_out.* = try listener.getBoundPort();
    return listener;
}

fn serveOne(listener: *Socket) void {
    const HttpServer = server_mod.Server(SocketConn, .{ .read_buf_size = 4096, .write_buf_size = 2048 });
    const server = HttpServer.init(testing.allocator, &test_routes);
    var client_sock = listener.accept() catch return;
    client_sock.setRecvTimeout(5000);
    var conn = SocketConn{ .sock = client_sock };
    server.serveConn(conn);
    _ = &conn;
}

fn httpGet(port: u16, path: []const u8, buf: []u8) ![]const u8 {
    var sock = try Socket.tcp();
    defer sock.close();
    sock.setRecvTimeout(5000);
    try sock.connect(.{ 127, 0, 0, 1 }, port);

    var req_buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&req_buf);
    const w = fbs.writer();
    try w.print("GET {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", .{path});
    _ = try sock.send(req_buf[0..fbs.pos]);

    var total: usize = 0;
    while (total < buf.len) {
        const n = sock.recv(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

fn httpPost(port: u16, path: []const u8, body: []const u8, buf: []u8) ![]const u8 {
    var sock = try Socket.tcp();
    defer sock.close();
    sock.setRecvTimeout(5000);
    try sock.connect(.{ 127, 0, 0, 1 }, port);

    var req_buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&req_buf);
    const w = fbs.writer();
    try w.print("POST {s} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ path, body.len });
    try w.writeAll(body);
    _ = try sock.send(req_buf[0..fbs.pos]);

    var total: usize = 0;
    while (total < buf.len) {
        const n = sock.recv(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

test "full request-response cycle" {
    const raw = "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var state = MockConn.State{ .input = raw };
    var conn = MockConn{ .state = &state };

    const routes = [_]Route{
        router_mod.get("/hello", testHandler),
    };

    const TestServer = server_mod.Server(MockConn, .{ .read_buf_size = 1024, .write_buf_size = 512 });
    const server = TestServer.init(testing.allocator, &routes);
    server.serveConn(conn);
    _ = &conn;

    const out = state.output[0..state.output_len];
    try testing.expect(mem.startsWith(u8, out, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(mem.indexOf(u8, out, "Content-Type: text/plain\r\n") != null);
    try testing.expect(mem.endsWith(u8, out, "Hello"));
    try testing.expect(state.closed);
}

test "keep-alive — multiple requests" {
    const raw =
        "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n" ++
        "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var state = MockConn.State{ .input = raw };
    var conn = MockConn{ .state = &state };

    const routes = [_]Route{
        router_mod.get("/hello", testHandler),
    };

    const TestServer = server_mod.Server(MockConn, .{ .read_buf_size = 2048, .write_buf_size = 512 });
    const server = TestServer.init(testing.allocator, &routes);
    server.serveConn(conn);
    _ = &conn;

    const out = state.output[0..state.output_len];
    var count: usize = 0;
    var pos: usize = 0;
    while (mem.indexOfPos(u8, out, pos, "HTTP/1.1 200 OK")) |idx| {
        count += 1;
        pos = idx + 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "Connection: close terminates" {
    const raw = "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var state = MockConn.State{ .input = raw };
    var conn = MockConn{ .state = &state };

    const routes = [_]Route{
        router_mod.get("/hello", testHandler),
    };

    const TestServer = server_mod.Server(MockConn, .{ .read_buf_size = 1024, .write_buf_size = 512 });
    const server = TestServer.init(testing.allocator, &routes);
    server.serveConn(conn);
    _ = &conn;

    try testing.expect(state.closed);
    const out = state.output[0..state.output_len];
    var count: usize = 0;
    var pos: usize = 0;
    while (mem.indexOfPos(u8, out, pos, "HTTP/1.1 200 OK")) |idx| {
        count += 1;
        pos = idx + 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "TCP loopback: single GET" {
    var port: u16 = 0;
    var listener = try startTestServer(&port);
    defer listener.close();

    const t = try std.Thread.spawn(.{}, serveOne, .{&listener});

    var buf: [4096]u8 = undefined;
    const resp = try httpGet(port, "/echo", &buf);
    try testing.expect(mem.indexOf(u8, resp, "HTTP/1.1 200 OK") != null);
    try testing.expect(mem.endsWith(u8, resp, "/echo"));

    t.join();
}

test "TCP loopback: POST with body" {
    var port: u16 = 0;
    var listener = try startTestServer(&port);
    defer listener.close();

    const t = try std.Thread.spawn(.{}, serveOne, .{&listener});

    var buf: [4096]u8 = undefined;
    const resp = try httpPost(port, "/echo", "hello world", &buf);
    try testing.expect(mem.indexOf(u8, resp, "HTTP/1.1 200 OK") != null);
    try testing.expect(mem.endsWith(u8, resp, "hello world"));

    t.join();
}

test "TCP loopback: JSON endpoint" {
    var port: u16 = 0;
    var listener = try startTestServer(&port);
    defer listener.close();

    const t = try std.Thread.spawn(.{}, serveOne, .{&listener});

    var buf: [4096]u8 = undefined;
    const resp = try httpGet(port, "/json", &buf);
    try testing.expect(mem.indexOf(u8, resp, "application/json") != null);
    try testing.expect(mem.endsWith(u8, resp, "{\"ok\":true}"));

    t.join();
}

test "TCP loopback: 404 for unknown path" {
    var port: u16 = 0;
    var listener = try startTestServer(&port);
    defer listener.close();

    const t = try std.Thread.spawn(.{}, serveOne, .{&listener});

    var buf: [4096]u8 = undefined;
    const resp = try httpGet(port, "/nonexistent", &buf);
    try testing.expect(mem.indexOf(u8, resp, "HTTP/1.1 404") != null);

    t.join();
}

test "TCP loopback: concurrent clients — 8 threads" {
    var port: u16 = 0;
    var listener = try startTestServer(&port);
    defer listener.close();

    const N = 8;

    var server_threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        server_threads[i] = try std.Thread.spawn(.{}, serveOne, .{&listener});
    }

    const results = struct {
        var success: [N]bool = .{false} ** N;
    };

    const ClientWorker = struct {
        fn run(p: u16, idx: usize) void {
            var buf: [4096]u8 = undefined;
            const resp = httpGet(p, "/echo", &buf) catch return;
            if (mem.indexOf(u8, resp, "HTTP/1.1 200 OK") != null) {
                results.success[idx] = true;
            }
        }
    };

    var client_threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        client_threads[i] = try std.Thread.spawn(.{}, ClientWorker.run, .{ port, i });
    }
    for (&client_threads) |*t| t.join();
    for (&server_threads) |*t| t.join();

    for (results.success) |s| {
        try testing.expect(s);
    }
}

test "TCP loopback: concurrent mixed GET+POST — 6 threads" {
    var port: u16 = 0;
    var listener = try startTestServer(&port);
    defer listener.close();

    const N = 6;

    var server_threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        server_threads[i] = try std.Thread.spawn(.{}, serveOne, .{&listener});
    }

    const results = struct {
        var success: [N]bool = .{false} ** N;
    };

    const MixedWorker = struct {
        fn run(p: u16, idx: usize) void {
            var buf: [4096]u8 = undefined;
            if (idx % 2 == 0) {
                const resp = httpGet(p, "/json", &buf) catch return;
                if (mem.indexOf(u8, resp, "200 OK") != null) results.success[idx] = true;
            } else {
                const body = "payload";
                const resp = httpPost(p, "/echo", body, &buf) catch return;
                if (mem.endsWith(u8, resp, body)) results.success[idx] = true;
            }
        }
    };

    var client_threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        client_threads[i] = try std.Thread.spawn(.{}, MixedWorker.run, .{ port, i });
    }
    for (&client_threads) |*t| t.join();
    for (&server_threads) |*t| t.join();

    for (results.success) |s| {
        try testing.expect(s);
    }
}

test "TCP loopback: rapid sequential requests on same port" {
    var port: u16 = 0;
    var listener = try startTestServer(&port);
    defer listener.close();

    for (0..5) |_| {
        const t = try std.Thread.spawn(.{}, serveOne, .{&listener});

        var buf: [4096]u8 = undefined;
        const resp = httpGet(port, "/echo", &buf) catch break;
        try testing.expect(mem.indexOf(u8, resp, "200 OK") != null);

        t.join();
    }
}

test "TCP loopback: concurrent slow + fast handlers" {
    var port: u16 = 0;
    var listener = try startTestServer(&port);
    defer listener.close();

    var s1 = try std.Thread.spawn(.{}, serveOne, .{&listener});
    var s2 = try std.Thread.spawn(.{}, serveOne, .{&listener});

    const results = struct {
        var fast_done: bool = false;
        var slow_done: bool = false;
    };

    const FastWorker = struct {
        fn run(p: u16) void {
            var buf: [4096]u8 = undefined;
            const resp = httpGet(p, "/echo", &buf) catch return;
            if (mem.indexOf(u8, resp, "200 OK") != null) results.fast_done = true;
        }
    };
    const SlowWorker = struct {
        fn run(p: u16) void {
            var buf: [4096]u8 = undefined;
            const resp = httpGet(p, "/slow", &buf) catch return;
            if (mem.endsWith(u8, resp, "slow")) results.slow_done = true;
        }
    };

    var c1 = try std.Thread.spawn(.{}, SlowWorker.run, .{port});
    std.Thread.sleep(2 * std.time.ns_per_ms);
    var c2 = try std.Thread.spawn(.{}, FastWorker.run, .{port});

    c1.join();
    c2.join();
    s1.join();
    s2.join();

    try testing.expect(results.fast_done or results.slow_done);
}
