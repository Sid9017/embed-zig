const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const response = embed.pkg.net.http.response;
const mem = std.mem;

const TestWriter = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    pub fn writeFn(ctx: *anyopaque, data: []const u8) response.Response.WriteError!void {
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

test "200 OK with body" {
    var tw = TestWriter{};
    var write_buf: [512]u8 = undefined;
    var resp = response.Response{
        .write_buf = &write_buf,
        .write_fn = TestWriter.writeFn,
        .write_ctx = @ptrCast(&tw),
    };

    resp.send("Hello, World!");

    const out = tw.output();
    try testing.expect(mem.startsWith(u8, out, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(mem.indexOf(u8, out, "Content-Length: 13\r\n") != null);
    try testing.expect(mem.endsWith(u8, out, "Hello, World!"));
}

test "JSON response" {
    var tw = TestWriter{};
    var write_buf: [512]u8 = undefined;
    var resp = response.Response{
        .write_buf = &write_buf,
        .write_fn = TestWriter.writeFn,
        .write_ctx = @ptrCast(&tw),
    };

    resp.json("{\"status\":\"ok\"}");

    const out = tw.output();
    try testing.expect(mem.indexOf(u8, out, "Content-Type: application/json\r\n") != null);
    try testing.expect(mem.endsWith(u8, out, "{\"status\":\"ok\"}"));
}

test "404 sendStatus" {
    var tw = TestWriter{};
    var write_buf: [512]u8 = undefined;
    var resp = response.Response{
        .write_buf = &write_buf,
        .write_fn = TestWriter.writeFn,
        .write_ctx = @ptrCast(&tw),
    };

    resp.sendStatus(404);

    const out = tw.output();
    try testing.expect(mem.startsWith(u8, out, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(mem.indexOf(u8, out, "Content-Length: 0\r\n") != null);
}

test "multiple headers" {
    var tw = TestWriter{};
    var write_buf: [512]u8 = undefined;
    var resp = response.Response{
        .write_buf = &write_buf,
        .write_fn = TestWriter.writeFn,
        .write_ctx = @ptrCast(&tw),
    };

    _ = resp.setHeader("X-Request-Id", "abc123").setHeader("Cache-Control", "no-cache");
    resp.send("ok");

    const out = tw.output();
    try testing.expect(mem.indexOf(u8, out, "X-Request-Id: abc123\r\n") != null);
    try testing.expect(mem.indexOf(u8, out, "Cache-Control: no-cache\r\n") != null);
    try testing.expect(mem.endsWith(u8, out, "ok"));
}

test "CRLF injection rejected" {
    var tw = TestWriter{};
    var write_buf: [512]u8 = undefined;
    var resp = response.Response{
        .write_buf = &write_buf,
        .write_fn = TestWriter.writeFn,
        .write_ctx = @ptrCast(&tw),
    };

    _ = resp.setHeader("X-Bad", "value\r\nInjected: yes");
    resp.send("ok");

    const out = tw.output();
    try testing.expect(mem.indexOf(u8, out, "Injected") == null);
}

test "statusText known codes" {
    try testing.expectEqualStrings("OK", response.statusText(200));
    try testing.expectEqualStrings("Not Found", response.statusText(404));
    try testing.expectEqualStrings("Internal Server Error", response.statusText(500));
    try testing.expectEqualStrings("Unknown", response.statusText(999));
}
