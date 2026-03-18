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
