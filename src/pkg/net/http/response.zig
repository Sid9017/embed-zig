const std = @import("std");
const mem = std.mem;
const request = @import("request.zig");

pub const Response = struct {
    write_buf: []u8,
    pos: usize = 0,
    headers_sent: bool = false,
    status_code: u16 = 200,

    write_fn: *const fn (ctx: *anyopaque, data: []const u8) WriteError!void,
    write_ctx: *anyopaque,

    pub const WriteError = error{
        SocketError,
        BufferOverflow,
    };

    pub fn status(self: *Response, code: u16) *Response {
        self.status_code = code;
        return self;
    }

    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) *Response {
        if (self.headers_sent) return self;
        if (containsCrlf(name) or containsCrlf(value)) return self;
        const needed = name.len + 2 + value.len + 2;
        const available = self.write_buf.len - self.pos;
        if (needed > available) return self;
        self.appendSlice(name);
        self.appendSlice(": ");
        self.appendSlice(value);
        self.appendSlice("\r\n");
        return self;
    }

    pub fn contentType(self: *Response, mime: []const u8) *Response {
        return self.setHeader("Content-Type", mime);
    }

    pub fn send(self: *Response, body: []const u8) void {
        self.sendFull(body, null);
    }

    pub fn json(self: *Response, body: []const u8) void {
        self.sendFull(body, "application/json");
    }

    pub fn sendStatus(self: *Response, code: u16) void {
        self.status_code = code;
        self.sendFull("", null);
    }

    fn sendFull(self: *Response, body: []const u8, content_type_override: ?[]const u8) void {
        if (self.headers_sent) return;
        self.headers_sent = true;

        var hdr_buf: [512]u8 = undefined;
        var hdr_pos: usize = 0;

        hdr_pos = appendBuf(&hdr_buf, hdr_pos, "HTTP/1.1 ");
        var code_buf: [3]u8 = undefined;
        hdr_pos = appendBuf(&hdr_buf, hdr_pos, writeStatusCode(&code_buf, self.status_code));
        hdr_pos = appendBuf(&hdr_buf, hdr_pos, " ");
        hdr_pos = appendBuf(&hdr_buf, hdr_pos, statusText(self.status_code));
        hdr_pos = appendBuf(&hdr_buf, hdr_pos, "\r\n");

        if (content_type_override) |ct| {
            hdr_pos = appendBuf(&hdr_buf, hdr_pos, "Content-Type: ");
            hdr_pos = appendBuf(&hdr_buf, hdr_pos, ct);
            hdr_pos = appendBuf(&hdr_buf, hdr_pos, "\r\n");
        }

        hdr_pos = appendBuf(&hdr_buf, hdr_pos, "Content-Length: ");
        var cl_buf: [20]u8 = undefined;
        hdr_pos = appendBuf(&hdr_buf, hdr_pos, request.writeUsize(&cl_buf, body.len) orelse "0");
        hdr_pos = appendBuf(&hdr_buf, hdr_pos, "\r\n");

        self.write_fn(self.write_ctx, hdr_buf[0..hdr_pos]) catch {};

        if (self.pos > 0) {
            self.write_fn(self.write_ctx, self.write_buf[0..self.pos]) catch {};
            self.pos = 0;
        }

        self.write_fn(self.write_ctx, "\r\n") catch {};

        if (body.len > 0) {
            self.write_fn(self.write_ctx, body) catch {};
        }
    }

    fn appendSlice(self: *Response, data: []const u8) void {
        const available = self.write_buf.len - self.pos;
        const to_copy = @min(data.len, available);
        if (to_copy > 0) {
            @memcpy(self.write_buf[self.pos .. self.pos + to_copy], data[0..to_copy]);
            self.pos += to_copy;
        }
    }
};

pub fn containsCrlf(s: []const u8) bool {
    for (s) |c| {
        if (c == '\r' or c == '\n') return true;
    }
    return false;
}

pub fn appendBuf(buf: []u8, pos: usize, data: []const u8) usize {
    const available = buf.len - pos;
    if (data.len > available) return pos;
    @memcpy(buf[pos .. pos + data.len], data);
    return pos + data.len;
}

pub fn writeStatusCode(buf: *[3]u8, code: u16) []const u8 {
    buf[0] = @intCast(code / 100 + '0');
    buf[1] = @intCast((code / 10) % 10 + '0');
    buf[2] = @intCast(code % 10 + '0');
    return buf;
}

pub fn statusText(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
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
