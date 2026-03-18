//! WebSocket Client — RFC 6455
//!
//! Generic over any type satisfying the `net.Conn` contract (read/write/close).
//! Works with plain TCP (via SocketConn), TLS streams, or any byte stream.
//!
//! Limitations:
//! - No message fragmentation (continuation frames). Messages must fit in a
//!   single frame. Sufficient for most WebSocket APIs.
//!
//! ## Usage
//!
//! ```zig
//! var client = try ws.Client(Conn).init(allocator, &conn, .{
//!     .host = "echo.websocket.org",
//!     .path = "/",
//!     .rng_fill = rng.fill,
//! });
//! defer client.deinit();
//!
//! try client.sendText("hello");
//! while (try client.recv()) |msg| {
//!     // msg.payload is valid until next recv()
//! }
//! ```

const Allocator = @import("std").mem.Allocator;
const embed = @import("../../../mod.zig");
const frame = @import("frame.zig");
const handshake_mod = @import("handshake.zig");

pub const Message = struct {
    type: MessageType,
    payload: []const u8,
};

pub const MessageType = enum {
    text,
    binary,
    ping,
    pong,
};

pub fn Client(comptime Conn: type) type {
    return struct {
        const Self = @This();

        pub const InitOptions = struct {
            host: []const u8,
            port: u16 = 443,
            path: []const u8 = "/",
            extra_headers: ?[]const [2][]const u8 = null,
            rng_fill: *const fn ([]u8) void,
            buffer_size: usize = 4096,
            mask_chunk_size: usize = 512,
        };

        conn: *Conn,
        read_buf: []u8,
        read_start: usize,
        read_end: usize,
        mask_buf: []u8,
        allocator: Allocator,
        rng_fill: *const fn ([]u8) void,
        state: State,

        const State = enum {
            open,
            closing,
            closed,
        };

        pub fn init(
            allocator: Allocator,
            conn: *Conn,
            opts: InitOptions,
        ) !Self {
            if (opts.mask_chunk_size == 0) return error.InvalidOptions;

            const read_buf = try allocator.alloc(u8, opts.buffer_size);
            errdefer allocator.free(read_buf);

            const mask_buf = try allocator.alloc(u8, opts.mask_chunk_size);
            errdefer allocator.free(mask_buf);

            const leftover = handshake_mod.performHandshake(
                conn,
                opts.host,
                opts.path,
                opts.extra_headers,
                read_buf,
                opts.rng_fill,
            ) catch |err| switch (err) {
                error.HandshakeFailed => return error.HandshakeFailed,
                error.InvalidResponse => return error.InvalidResponse,
                error.InvalidAcceptKey => return error.InvalidAcceptKey,
                error.ResponseTooLarge => return error.ResponseTooLarge,
                error.SendFailed => return error.SendFailed,
                error.RecvFailed => return error.RecvFailed,
                error.Closed => return error.Closed,
            };

            return .{
                .conn = conn,
                .read_buf = read_buf,
                .read_start = 0,
                .read_end = leftover,
                .mask_buf = mask_buf,
                .allocator = allocator,
                .rng_fill = opts.rng_fill,
                .state = .open,
            };
        }

        /// Initialize without performing handshake. For testing or pre-handshaked connections.
        pub fn initRaw(
            allocator: Allocator,
            conn: *Conn,
            opts: struct {
                rng_fill: *const fn ([]u8) void,
                buffer_size: usize = 4096,
                mask_chunk_size: usize = 512,
            },
        ) !Self {
            if (opts.mask_chunk_size == 0) return error.InvalidOptions;

            const read_buf = try allocator.alloc(u8, opts.buffer_size);
            errdefer allocator.free(read_buf);

            const mask_buf = try allocator.alloc(u8, opts.mask_chunk_size);
            errdefer allocator.free(mask_buf);

            return .{
                .conn = conn,
                .read_buf = read_buf,
                .read_start = 0,
                .read_end = 0,
                .mask_buf = mask_buf,
                .allocator = allocator,
                .rng_fill = opts.rng_fill,
                .state = .open,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.mask_buf);
            self.allocator.free(self.read_buf);
            self.state = .closed;
        }

        pub fn sendText(self: *Self, data: []const u8) !void {
            try self.sendFrame(.text, data);
        }

        pub fn sendBinary(self: *Self, data: []const u8) !void {
            try self.sendFrame(.binary, data);
        }

        pub fn sendPing(self: *Self) !void {
            try self.sendFrame(.ping, "");
        }

        pub fn sendPong(self: *Self, data: []const u8) !void {
            try self.sendFrame(.pong, data);
        }

        pub fn sendClose(self: *Self, code: u16) !void {
            const payload = [2]u8{
                @intCast(code >> 8),
                @intCast(code & 0xFF),
            };
            try self.sendFrame(.close, &payload);
            self.state = .closing;
        }

        /// Receive the next message. Returns null on connection close.
        /// The returned payload slice is valid until the next call to recv().
        ///
        /// Automatically responds to ping frames with pong.
        pub fn recv(self: *Self) !?Message {
            if (self.state == .closed) return null;

            while (true) {
                const prev_start = self.read_start;
                if (try self.tryParseFrame()) |msg| {
                    return msg;
                }

                if (self.state == .closed) return null;

                if (self.read_start != prev_start) continue;

                try self.readMore();
            }
        }

        pub fn close(self: *Self) void {
            if (self.state == .open) {
                self.sendClose(1000) catch {};
            }
            self.state = .closed;
        }

        // ==================================================================
        // Internal
        // ==================================================================

        fn sendFrame(self: *Self, opcode: frame.Opcode, payload: []const u8) !void {
            if (self.state == .closed) return error.Closed;

            var mask_key: [4]u8 = undefined;
            self.rng_fill(&mask_key);

            var hdr_buf: [frame.MAX_HEADER_SIZE]u8 = undefined;
            const hdr_len = frame.encodeHeader(&hdr_buf, opcode, payload.len, true, mask_key);

            writeAll(self.conn, hdr_buf[0..hdr_len]) catch {
                self.state = .closed;
                return error.SendFailed;
            };

            var offset: usize = 0;
            while (offset < payload.len) {
                const chunk_size = @min(self.mask_buf.len, payload.len - offset);
                @memcpy(self.mask_buf[0..chunk_size], payload[offset..][0..chunk_size]);
                frame.applyMaskOffset(self.mask_buf[0..chunk_size], mask_key, offset);
                writeAll(self.conn, self.mask_buf[0..chunk_size]) catch {
                    self.state = .closed;
                    return error.SendFailed;
                };
                offset += chunk_size;
            }
        }

        fn tryParseFrame(self: *Self) !?Message {
            const buffered = self.read_buf[self.read_start..self.read_end];
            if (buffered.len < 2) return null;

            const header = frame.decodeHeader(buffered) catch |err| switch (err) {
                error.TruncatedHeader => return null,
                else => return err,
            };

            if (header.payload_len > buffered.len) return null;
            const payload_len: usize = @intCast(header.payload_len);

            const total_frame_size = header.header_size + payload_len;
            if (buffered.len < total_frame_size) return null;

            const payload_start = self.read_start + header.header_size;
            const payload_end = payload_start + payload_len;

            if (header.masked) {
                frame.applyMask(self.read_buf[payload_start..payload_end], header.mask_key);
            }

            const payload = self.read_buf[payload_start..payload_end];
            self.read_start += total_frame_size;

            switch (header.opcode) {
                .ping => {
                    self.sendPong(payload) catch {};
                    return Message{ .type = .ping, .payload = payload };
                },
                .close => {
                    if (self.state == .open) {
                        self.sendClose(1000) catch {};
                    }
                    self.state = .closed;
                    return null;
                },
                .text => {
                    if (!header.fin) return error.FragmentedMessage;
                    return Message{ .type = .text, .payload = payload };
                },
                .binary => {
                    if (!header.fin) return error.FragmentedMessage;
                    return Message{ .type = .binary, .payload = payload };
                },
                .pong => return Message{ .type = .pong, .payload = payload },
                else => return null,
            }
        }

        fn readMore(self: *Self) !void {
            if (self.read_start > 0) {
                const remaining = self.read_end - self.read_start;
                if (remaining > 0) {
                    copyForward(self.read_buf, self.read_buf[self.read_start..self.read_end]);
                }
                self.read_end = remaining;
                self.read_start = 0;
            }

            if (self.read_end >= self.read_buf.len) return error.ResponseTooLarge;

            const n = self.conn.read(self.read_buf[self.read_end..]) catch {
                self.state = .closed;
                return error.Closed;
            };
            if (n == 0) {
                self.state = .closed;
                return error.Closed;
            }
            self.read_end += n;
        }
    };
}

pub fn copyForward(dst: []u8, src: []const u8) void {
    for (src, 0..) |b, i| {
        dst[i] = b;
    }
}

pub fn writeAll(conn: anytype, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        const n = conn.write(data[sent..]) catch return error.SendFailed;
        if (n == 0) return error.Closed;
        sent += n;
    }
}
