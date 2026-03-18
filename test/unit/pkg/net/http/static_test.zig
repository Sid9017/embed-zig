const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const static = embed.pkg.net.http.static;
const mem = std.mem;
const request_mod = embed.pkg.net.http.request;
const response_mod = embed.pkg.net.http.response;
const router_mod = embed.pkg.net.http.router;
const Request = request_mod.Request;
const Response = response_mod.Response;

const TestWriter = struct {
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

const test_files = [_]static.EmbeddedFile{
    .{ .path = "/static/app.js", .data = "console.log('hello');", .mime = "application/javascript" },
    .{ .path = "/static/style.css", .data = "body { margin: 0; }", .mime = "text/css" },
};

test "embedded file hit" {
    var tw = TestWriter{};
    var write_buf: [512]u8 = undefined;
    var resp = Response{
        .write_buf = &write_buf,
        .write_fn = TestWriter.writeFn,
        .write_ctx = @ptrCast(&tw),
    };
    var req = Request{
        .method = .GET,
        .path = "/static/app.js",
        .query = null,
        .version = "HTTP/1.1",
        .header_bytes = "",
        .body = null,
        .content_length = 0,
    };

    const handler = static.serveEmbedded(&test_files);
    handler(&req, &resp);

    const out = tw.output();
    try testing.expect(mem.indexOf(u8, out, "Content-Type: application/javascript\r\n") != null);
    try testing.expect(mem.endsWith(u8, out, "console.log('hello');"));
}

test "embedded file 404" {
    var tw = TestWriter{};
    var write_buf: [512]u8 = undefined;
    var resp = Response{
        .write_buf = &write_buf,
        .write_fn = TestWriter.writeFn,
        .write_ctx = @ptrCast(&tw),
    };
    var req = Request{
        .method = .GET,
        .path = "/static/nonexistent.js",
        .query = null,
        .version = "HTTP/1.1",
        .header_bytes = "",
        .body = null,
        .content_length = 0,
    };

    const handler = static.serveEmbedded(&test_files);
    handler(&req, &resp);

    const out = tw.output();
    try testing.expect(mem.startsWith(u8, out, "HTTP/1.1 404 Not Found\r\n"));
}

test "mimeFromPath" {
    try testing.expectEqualStrings("text/html", static.mimeFromPath("/index.html"));
    try testing.expectEqualStrings("text/css", static.mimeFromPath("/style.css"));
    try testing.expectEqualStrings("application/javascript", static.mimeFromPath("/app.js"));
    try testing.expectEqualStrings("application/json", static.mimeFromPath("/data.json"));
    try testing.expectEqualStrings("image/png", static.mimeFromPath("/logo.png"));
    try testing.expectEqualStrings("application/octet-stream", static.mimeFromPath("/unknown.xyz"));
}
