//! WebSocket Handshake — RFC 6455 Section 4
//!
//! Performs the HTTP Upgrade handshake over an existing Conn.
//! Generates Sec-WebSocket-Key and validates Sec-WebSocket-Accept.
//!
//! Generic over any type satisfying the `net.Conn` contract (read/write/close).

const sha1 = @import("sha1.zig");
const base64 = @import("base64.zig");
const client_mod = @import("client.zig");

pub const Error = error{
    HandshakeFailed,
    InvalidResponse,
    InvalidAcceptKey,
    ResponseTooLarge,
    SendFailed,
    RecvFailed,
    Closed,
};

pub const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub fn computeAcceptKey(key: []const u8, out: *[28]u8) void {
    var h = sha1.init();
    h.update(key);
    h.update(ws_guid);
    const digest = h.final();
    _ = base64.encode(out, &digest);
}

pub fn buildRequest(
    buf: []u8,
    host: []const u8,
    path: []const u8,
    ws_key: []const u8,
    extra_headers: ?[]const [2][]const u8,
) ![]const u8 {
    var writer = BufWriter{ .buf = buf };

    try writer.writeSlice("GET ");
    try writer.writeSlice(path);
    try writer.writeSlice(" HTTP/1.1\r\n");

    try writer.writeSlice("Host: ");
    try writer.writeSlice(host);
    try writer.writeSlice("\r\n");

    try writer.writeSlice("Upgrade: websocket\r\n");
    try writer.writeSlice("Connection: Upgrade\r\n");

    try writer.writeSlice("Sec-WebSocket-Key: ");
    try writer.writeSlice(ws_key);
    try writer.writeSlice("\r\n");

    try writer.writeSlice("Sec-WebSocket-Version: 13\r\n");

    if (extra_headers) |headers| {
        for (headers) |hdr| {
            try writer.writeSlice(hdr[0]);
            try writer.writeSlice(": ");
            try writer.writeSlice(hdr[1]);
            try writer.writeSlice("\r\n");
        }
    }

    try writer.writeSlice("\r\n");
    return buf[0..writer.pos];
}

pub fn validateResponse(
    response: []const u8,
    expected_accept: []const u8,
) Error!usize {
    const header_end = findHeaderEnd(response) orelse return error.InvalidResponse;
    const header_data = response[0..header_end];

    if (!startsWith(header_data, "HTTP/1.1 101") and !startsWith(header_data, "HTTP/1.0 101"))
        return error.HandshakeFailed;

    const accept_value = findHeaderValue(header_data, "Sec-WebSocket-Accept") orelse
        return error.InvalidAcceptKey;

    if (!eql(accept_value, expected_accept))
        return error.InvalidAcceptKey;

    return header_end + 4;
}

/// Perform the full WebSocket handshake over a Conn.
///
/// `conn` must satisfy the `net.Conn` contract (read/write/close).
/// `rng_fill` fills a buffer with random bytes for the WebSocket key.
pub fn performHandshake(
    conn: anytype,
    host: []const u8,
    path: []const u8,
    extra_headers: ?[]const [2][]const u8,
    buf: []u8,
    rng_fill: *const fn ([]u8) void,
) Error!usize {
    var key_bytes: [16]u8 = undefined;
    rng_fill(&key_bytes);

    var ws_key: [24]u8 = undefined;
    _ = base64.encode(&ws_key, &key_bytes);

    var expected_accept: [28]u8 = undefined;
    computeAcceptKey(&ws_key, &expected_accept);

    const request = buildRequest(buf, host, path, &ws_key, extra_headers) catch
        return error.ResponseTooLarge;

    writeAll(conn, request) catch return error.SendFailed;

    var resp_len: usize = 0;
    while (resp_len < buf.len) {
        const n = conn.read(buf[resp_len..]) catch |err| switch (err) {
            error.Closed => return error.Closed,
            else => return error.RecvFailed,
        };
        if (n == 0) return error.Closed;
        resp_len += n;

        if (findHeaderEnd(buf[0..resp_len])) |_| {
            const consumed = try validateResponse(buf[0..resp_len], &expected_accept);
            const leftover = resp_len - consumed;
            if (leftover > 0) {
                client_mod.copyForward(buf, buf[consumed..resp_len]);
            }
            return leftover;
        }
    }

    return error.ResponseTooLarge;
}

// ==========================================================================
// Helpers
// ==========================================================================

pub fn writeAll(conn: anytype, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        const n = conn.write(data[sent..]) catch return error.SendFailed;
        if (n == 0) return error.Closed;
        sent += n;
    }
}

pub fn findHeaderEnd(data: []const u8) ?usize {
    if (data.len < 4) return null;
    for (0..data.len - 3) |i| {
        if (data[i] == '\r' and data[i + 1] == '\n' and data[i + 2] == '\r' and data[i + 3] == '\n')
            return i;
    }
    return null;
}

pub fn findHeaderValue(header: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < header.len) {
        const line_start = i;
        while (i < header.len and header[i] != '\r') : (i += 1) {}
        const line = header[line_start..i];
        if (i < header.len) {
            i += if (i + 1 < header.len and header[i + 1] == '\n') @as(usize, 2) else 1;
        }

        if (line.len > name.len and eqlIgnoreCase(line[0..name.len], name) and line[name.len] == ':') {
            var val_start = name.len + 1;
            while (val_start < line.len and line[val_start] == ' ') : (val_start += 1) {}
            return line[val_start..];
        }
    }
    return null;
}

pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLower(ca) != toLower(cb)) return false;
    }
    return true;
}

pub fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

pub fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return eql(haystack[0..prefix.len], prefix);
}

pub const BufWriter = struct {
    buf: []u8,
    pos: usize = 0,

    const WriteError = error{ResponseTooLarge};

    pub fn writeSlice(self: *BufWriter, data: []const u8) WriteError!void {
        if (self.pos + data.len > self.buf.len) return error.ResponseTooLarge;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }
};
