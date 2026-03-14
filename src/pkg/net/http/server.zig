const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const request_mod = @import("request.zig");
const response_mod = @import("response.zig");
const router_mod = @import("router.zig");

const Request = request_mod.Request;
const Response = response_mod.Response;
const Route = router_mod.Route;
const Handler = router_mod.Handler;

pub const Config = struct {
    read_buf_size: usize = 8192,
    write_buf_size: usize = 4096,
    max_requests_per_conn: usize = 100,
};

/// HTTP/1.1 Server generic over a connection type.
///
/// `Conn` must implement `recv([]u8) !usize`, `send([]const u8) !usize`, `close() void`.
/// User controls the accept loop; server handles per-connection request/response.
pub fn Server(comptime Conn: type, comptime config: Config) type {
    return struct {
        const Self = @This();

        routes: []const Route,
        allocator: Allocator,

        pub fn init(allocator: Allocator, routes: []const Route) Self {
            return .{
                .routes = routes,
                .allocator = allocator,
            };
        }

        pub fn serveConn(self: *const Self, connection: Conn) void {
            var conn = connection;
            defer conn.close();

            const read_buf = self.allocator.alloc(u8, config.read_buf_size) catch return;
            defer self.allocator.free(read_buf);

            const write_buf = self.allocator.alloc(u8, config.write_buf_size) catch return;
            defer self.allocator.free(write_buf);

            var buffered: usize = 0;
            var requests_served: usize = 0;
            var need_more_data = false;

            while (requests_served < config.max_requests_per_conn) {
                while (need_more_data or mem.indexOf(u8, read_buf[0..buffered], "\r\n\r\n") == null) {
                    if (buffered >= read_buf.len) break;

                    const n = conn.recv(read_buf[buffered..]) catch |err| {
                        switch (err) {
                            error.Timeout => {
                                if (buffered == 0) return;
                                if (need_more_data) {
                                    sendError(&conn, write_buf, 408);
                                    return;
                                }
                                break;
                            },
                            error.Closed => return,
                            else => return,
                        }
                    };
                    if (n == 0) return;
                    buffered += n;
                    need_more_data = false;
                }

                const result = request_mod.parse(read_buf[0..buffered]) catch |err| {
                    switch (err) {
                        error.Incomplete => {
                            if (buffered >= read_buf.len) {
                                sendError(&conn, write_buf, 413);
                                return;
                            }
                            need_more_data = true;
                            continue;
                        },
                        else => {
                            sendError(&conn, write_buf, 400);
                            return;
                        },
                    }
                };

                var req = result.request;
                var resp = Response{
                    .write_buf = write_buf,
                    .write_fn = connWriteFn(Conn),
                    .write_ctx = @ptrCast(&conn),
                };

                const route_match = router_mod.match(self.routes, req.method, req.path);
                switch (route_match.result) {
                    .found => route_match.handler.?(&req, &resp),
                    .not_found => resp.sendStatus(404),
                    .method_not_allowed => resp.sendStatus(405),
                }

                requests_served += 1;

                const is_http10 = mem.eql(u8, req.version, "HTTP/1.0");
                if (req.header("Connection")) |conn_header| {
                    if (std.ascii.eqlIgnoreCase(conn_header, "close")) return;
                    if (is_http10 and !std.ascii.eqlIgnoreCase(conn_header, "keep-alive")) return;
                } else if (is_http10) {
                    return;
                }

                const consumed = result.consumed;
                if (consumed < buffered) {
                    mem.copyForwards(u8, read_buf[0 .. buffered - consumed], read_buf[consumed..buffered]);
                    buffered -= consumed;
                } else {
                    buffered = 0;
                }
            }
        }

        fn sendError(conn: *Conn, write_buf: []u8, code: u16) void {
            var resp = Response{
                .write_buf = write_buf,
                .write_fn = connWriteFn(Conn),
                .write_ctx = @ptrCast(conn),
            };
            resp.sendStatus(code);
        }
    };
}

pub fn connWriteFn(comptime Conn: type) *const fn (*anyopaque, []const u8) Response.WriteError!void {
    return struct {
        fn write(ctx: *anyopaque, data: []const u8) Response.WriteError!void {
            const c: *Conn = @ptrCast(@alignCast(ctx));
            var sent: usize = 0;
            while (sent < data.len) {
                sent += c.send(data[sent..]) catch return error.SocketError;
            }
        }
    }.write;
}

const testing = std.testing;

pub const MockConn = struct {
    state: *State,

    pub const State = struct {
        input: []const u8,
        input_pos: usize = 0,
        output: [8192]u8 = undefined,
        output_len: usize = 0,
        closed: bool = false,

        fn getOutput(self: *const State) []const u8 {
            return self.output[0..self.output_len];
        }
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

pub fn testHandler(_: *Request, resp: *Response) void {
    _ = resp.contentType("text/plain");
    resp.send("Hello");
}

// =========================================================================
// Real TCP loopback concurrency tests
// =========================================================================

pub const runtime = struct {
    pub const std = @import("../../../runtime/std.zig");
};
pub const Socket = runtime.std.Socket;

pub const SocketConn = struct {
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

pub fn echoHandler(req: *Request, resp: *Response) void {
    _ = resp.contentType("text/plain");
    if (req.body) |b| {
        resp.send(b);
    } else {
        resp.send(req.path);
    }
}

pub fn jsonHandler(_: *Request, resp: *Response) void {
    resp.json("{\"ok\":true}");
}

pub fn slowHandler(_: *Request, resp: *Response) void {
    std.Thread.sleep(10 * std.time.ns_per_ms);
    resp.send("slow");
}

pub const test_routes = [_]Route{
    router_mod.get("/echo", echoHandler),
    router_mod.get("/json", jsonHandler),
    router_mod.post("/echo", echoHandler),
    router_mod.get("/slow", slowHandler),
};

pub fn startTestServer(port_out: *u16) !Socket {
    var listener = try Socket.tcp();
    try listener.bind(.{ 127, 0, 0, 1 }, 0);
    try listener.listen();
    port_out.* = try listener.getBoundPort();
    return listener;
}

pub fn serveOne(listener: *Socket) void {
    const HttpServer = Server(SocketConn, .{ .read_buf_size = 4096, .write_buf_size = 2048 });
    const server = HttpServer.init(testing.allocator, &test_routes);
    var client_sock = listener.accept() catch return;
    client_sock.setRecvTimeout(5000);
    var conn = SocketConn{ .sock = client_sock };
    server.serveConn(conn);
    _ = &conn;
}

pub fn httpGet(port: u16, path: []const u8, buf: []u8) ![]const u8 {
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

pub fn httpPost(port: u16, path: []const u8, body: []const u8, buf: []u8) ![]const u8 {
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
