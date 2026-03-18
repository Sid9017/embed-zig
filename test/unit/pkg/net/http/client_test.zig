const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const client = embed.pkg.net.http.client;
const request = embed.pkg.net.http.request;
const transport = embed.pkg.net.http.transport;

const MockTransport = struct {
    call_count: usize = 0,
    last_method: ?request.Method = null,
    last_host: ?[]const u8 = null,
    last_path: ?[]const u8 = null,
    last_scheme: ?transport.Scheme = null,
    response_text: []const u8 = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK",

    pub fn roundTrip(self: *MockTransport, req: transport.RoundTripRequest, buffer: []u8) transport.TransportError!transport.RoundTripResponse {
        self.call_count += 1;
        self.last_method = req.method;
        self.last_host = req.host;
        self.last_path = req.path;
        self.last_scheme = req.scheme;

        const text = self.response_text;
        if (text.len > buffer.len) return error.BufferTooSmall;
        @memcpy(buffer[0..text.len], text);

        if (text.len < 12) return error.InvalidResponse;
        if (!std.mem.startsWith(u8, text, "HTTP/1.")) return error.InvalidResponse;

        const status_code = std.fmt.parseInt(u16, text[9..12], 10) catch return error.InvalidResponse;

        var headers_end: usize = 0;
        if (text.len >= 4) {
            for (0..text.len - 3) |i| {
                if (std.mem.eql(u8, text[i .. i + 4], "\r\n\r\n")) {
                    headers_end = i + 4;
                    break;
                }
            }
        }
        if (headers_end == 0) return error.InvalidResponse;

        return .{
            .status_code = status_code,
            .content_length = text.len - headers_end,
            .chunked = false,
            .headers_end = headers_end,
            .body_start = headers_end,
            .buffer = buffer,
            .buffer_len = text.len,
        };
    }
};

fn initMockClient(mock: *MockTransport) client.Client(MockTransport) {
    return .{ .transport = mock };
}

test "Client.get dispatches to transport" {
    var mock = MockTransport{};
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    const resp = try c.get("http://example.com/api", &buf);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
    try std.testing.expectEqual(request.Method.GET, mock.last_method.?);
    try std.testing.expectEqualStrings("example.com", mock.last_host.?);
    try std.testing.expectEqualStrings("/api", mock.last_path.?);
}

test "Client.post dispatches to transport" {
    var mock = MockTransport{};
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    _ = try c.post("http://example.com/submit", "data", &buf);
    try std.testing.expectEqual(request.Method.POST, mock.last_method.?);
}

test "Client.postJson dispatches to transport" {
    var mock = MockTransport{};
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    _ = try c.postJson("http://example.com/api", "{}", &buf);
    try std.testing.expectEqual(request.Method.POST, mock.last_method.?);
}

test "Client.put dispatches to transport" {
    var mock = MockTransport{};
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    _ = try c.put("http://example.com/resource", "data", &buf);
    try std.testing.expectEqual(request.Method.PUT, mock.last_method.?);
}

test "Client.delete dispatches to transport" {
    var mock = MockTransport{};
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    _ = try c.delete("http://example.com/resource", &buf);
    try std.testing.expectEqual(request.Method.DELETE, mock.last_method.?);
}

test "Client detects HTTPS scheme" {
    var mock = MockTransport{};
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    _ = try c.get("https://secure.example.com/api", &buf);
    try std.testing.expectEqual(transport.Scheme.https, mock.last_scheme.?);
    try std.testing.expectEqualStrings("secure.example.com", mock.last_host.?);
}

test "Client invalid URL returns error" {
    var mock = MockTransport{};
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    try std.testing.expectError(error.InvalidUrl, c.get("not a url at all", &buf));
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);
}

test "Client multiple sequential requests" {
    var mock = MockTransport{};
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    _ = try c.get("http://a.com/1", &buf);
    _ = try c.get("http://b.com/2", &buf);
    _ = try c.post("http://c.com/3", null, &buf);
    try std.testing.expectEqual(@as(usize, 3), mock.call_count);
}

test "Client response body access" {
    var mock = MockTransport{
        .response_text = "HTTP/1.1 201 Created\r\nContent-Length: 11\r\n\r\n{\"id\": 123}",
    };
    var c = initMockClient(&mock);
    var buf: [256]u8 = undefined;

    const resp = try c.post("http://api.example.com/create", "{}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status_code);
    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqualStrings("{\"id\": 123}", resp.body());
}
