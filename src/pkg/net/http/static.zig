const std = @import("std");
const mem = std.mem;
const request_mod = @import("request.zig");
const response_mod = @import("response.zig");
const router_mod = @import("router.zig");

const Request = request_mod.Request;
const Response = response_mod.Response;

pub const EmbeddedFile = struct {
    path: []const u8,
    data: []const u8,
    mime: []const u8,
};

pub fn serveEmbedded(comptime files: []const EmbeddedFile) router_mod.Handler {
    return struct {
        fn handler(req: *Request, resp: *Response) void {
            for (files) |file| {
                if (mem.eql(u8, req.path, file.path)) {
                    _ = resp.contentType(file.mime);
                    resp.send(file.data);
                    return;
                }
            }
            resp.sendStatus(404);
        }
    }.handler;
}

pub fn mimeFromPath(path: []const u8) []const u8 {
    if (endsWith(path, ".html") or endsWith(path, ".htm")) return "text/html";
    if (endsWith(path, ".css")) return "text/css";
    if (endsWith(path, ".js")) return "application/javascript";
    if (endsWith(path, ".json")) return "application/json";
    if (endsWith(path, ".png")) return "image/png";
    if (endsWith(path, ".jpg") or endsWith(path, ".jpeg")) return "image/jpeg";
    if (endsWith(path, ".gif")) return "image/gif";
    if (endsWith(path, ".svg")) return "image/svg+xml";
    if (endsWith(path, ".ico")) return "image/x-icon";
    if (endsWith(path, ".txt")) return "text/plain";
    if (endsWith(path, ".xml")) return "application/xml";
    if (endsWith(path, ".wasm")) return "application/wasm";
    return "application/octet-stream";
}

pub fn endsWith(haystack: []const u8, suffix: []const u8) bool {
    return mem.endsWith(u8, haystack, suffix);
}

const testing = std.testing;

pub const TestWriter = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    pub fn writeFn(ctx: *anyopaque, data: []const u8) Response.WriteError!void {
        const self: *TestWriter = @ptrCast(@alignCast(ctx));
        const end = self.len + data.len;
        if (end > self.buf.len) return error.BufferOverflow;
        @memcpy(self.buf[self.len..end], data);
        self.len = end;
    }

    pub fn output(self: *const TestWriter) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const test_files = [_]EmbeddedFile{
    .{ .path = "/static/app.js", .data = "console.log('hello');", .mime = "application/javascript" },
    .{ .path = "/static/style.css", .data = "body { margin: 0; }", .mime = "text/css" },
};
