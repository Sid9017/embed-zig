const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    PATCH,

    pub fn fromString(str: []const u8) ?Method {
        if (mem.eql(u8, str, "GET")) return .GET;
        if (mem.eql(u8, str, "POST")) return .POST;
        if (mem.eql(u8, str, "PUT")) return .PUT;
        if (mem.eql(u8, str, "DELETE")) return .DELETE;
        if (mem.eql(u8, str, "HEAD")) return .HEAD;
        if (mem.eql(u8, str, "OPTIONS")) return .OPTIONS;
        if (mem.eql(u8, str, "PATCH")) return .PATCH;
        return null;
    }

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .PATCH => "PATCH",
        };
    }
};

pub const HeaderIterator = struct {
    raw: []const u8,
    pos: usize,

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn next(self: *HeaderIterator) ?Header {
        while (self.pos < self.raw.len) {
            const remaining = self.raw[self.pos..];
            const line_end = mem.indexOf(u8, remaining, "\r\n") orelse return null;
            const line = remaining[0..line_end];
            self.pos += line_end + 2;

            if (line.len == 0) return null;

            const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
            return .{
                .name = mem.trim(u8, line[0..colon], " \t"),
                .value = mem.trim(u8, line[colon + 1 ..], " \t"),
            };
        }
        return null;
    }

    pub fn reset(self: *HeaderIterator) void {
        self.pos = 0;
    }
};

pub const Request = struct {
    method: Method,
    path: []const u8,
    query: ?[]const u8,
    version: []const u8,
    header_bytes: []const u8,
    body: ?[]const u8,
    content_length: usize,

    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        var iter = HeaderIterator{ .raw = self.header_bytes, .pos = 0 };
        while (iter.next()) |h| {
            if (ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    pub fn headers(self: *const Request) HeaderIterator {
        return .{ .raw = self.header_bytes, .pos = 0 };
    }
};

pub const ParseError = error{
    Incomplete,
    InvalidMethod,
    InvalidRequestLine,
    InvalidVersion,
    InvalidContentLength,
};

pub const ParseResult = struct {
    request: Request,
    consumed: usize,
};

pub fn parse(buf: []const u8) ParseError!ParseResult {
    const header_end_offset = mem.indexOf(u8, buf, "\r\n\r\n") orelse return error.Incomplete;
    const header_section_end = header_end_offset + 4;

    const request_line_end = mem.indexOf(u8, buf, "\r\n") orelse return error.Incomplete;
    const request_line = buf[0..request_line_end];

    const method_end = mem.indexOfScalar(u8, request_line, ' ') orelse return error.InvalidRequestLine;
    const method_str = request_line[0..method_end];
    const method = Method.fromString(method_str) orelse return error.InvalidMethod;

    const rest_after_method = request_line[method_end + 1 ..];
    const path_end = mem.indexOfScalar(u8, rest_after_method, ' ') orelse return error.InvalidRequestLine;
    const raw_path = rest_after_method[0..path_end];

    const version = rest_after_method[path_end + 1 ..];
    if (version.len < 8 or !mem.startsWith(u8, version, "HTTP/")) return error.InvalidVersion;

    var path: []const u8 = raw_path;
    var query: ?[]const u8 = null;
    if (mem.indexOfScalar(u8, raw_path, '?')) |qi| {
        path = raw_path[0..qi];
        query = raw_path[qi + 1 ..];
    }

    const header_bytes = buf[request_line_end + 2 .. header_end_offset + 2];

    var content_length: usize = 0;
    {
        var iter = HeaderIterator{ .raw = header_bytes, .pos = 0 };
        while (iter.next()) |h| {
            if (ascii.eqlIgnoreCase(h.name, "Content-Length")) {
                content_length = std.fmt.parseUnsigned(usize, h.value, 10) catch
                    return error.InvalidContentLength;
                break;
            }
        }
    }

    const body_start = header_section_end;
    const available_body = if (body_start < buf.len) buf.len - body_start else 0;
    if (available_body < content_length) return error.Incomplete;

    const body: ?[]const u8 = if (content_length > 0)
        buf[body_start .. body_start + content_length]
    else
        null;

    return .{
        .request = .{
            .method = method,
            .path = path,
            .query = query,
            .version = version,
            .header_bytes = header_bytes,
            .body = body,
            .content_length = content_length,
        },
        .consumed = body_start + content_length,
    };
}

pub fn writeUsize(buf: []u8, value: usize) ?[]const u8 {
    if (buf.len == 0) return null;
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = value;
    var len: usize = 0;
    while (v > 0 and len < buf.len) : (len += 1) {
        buf[len] = @intCast(v % 10 + '0');
        v /= 10;
    }
    if (v > 0) return null;
    var i: usize = 0;
    var j: usize = len - 1;
    while (i < j) {
        const tmp = buf[i];
        buf[i] = buf[j];
        buf[j] = tmp;
        i += 1;
        j -= 1;
    }
    return buf[0..len];
}
