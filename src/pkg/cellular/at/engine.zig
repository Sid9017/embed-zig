//! AT command engine: sendRaw, send(Cmd), pumpUrcs. Io is non-blocking read; Time drives timeouts.
//! See plan.md §5.5 and R40 (single flat rx_buf).

const std = @import("std");
const io = @import("../io/io.zig");
const parse = @import("parse.zig");

/// Result of parsing the modem's final response line(s).
pub const AtStatus = enum {
    ok,
    /// Bare `ERROR` line (not +CME/+CMS).
    gen_error,
    /// Io write/read failure (transport).
    io_error,
    cme_error,
    cms_error,
    timeout,
    overflow,
};

fn trimTrailingCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn trimBodyEnd(slice: []const u8) []const u8 {
    var e = slice.len;
    while (e > 0 and (slice[e - 1] == '\r' or slice[e - 1] == '\n')) e -= 1;
    return slice[0..e];
}

/// RX accumulator for one AT transaction (`rx_buf` + `rx_len`).
///
/// **Why this is a separate comptime type:** In Zig 0.15, declaring
/// `rx_buf: [buf_size]u8` inside the same anonymous struct as `time: Time` (the
/// `return struct { ... }` of `AtEngine`) makes the parser fail with
/// `expected type expression, found '<'`. Instantiating `[buf_size]` only inside
/// this helper type (`AtEngine` then embeds `rx: RxChunk(buf_size)`) avoids that.
/// Evaluated at **comptime** whenever `AtEngine(Time, buf_size)` is monomorphized.
fn RxChunk(comptime buf_size: usize) type {
    return struct {
        rx_buf: [buf_size]u8 = [_]u8{0} ** buf_size,
        rx_len: usize = 0,
    };
}

pub fn AtEngine(comptime Time: type, comptime buf_size: usize) type {
    comptime {
        _ = @as(*const fn (Time) u64, &Time.nowMs);
        _ = @as(*const fn (Time, u32) void, &Time.sleepMs);
    }
    const Rx = RxChunk(buf_size);
    return struct {
        io_instance: io.Io,
        time: Time,
        rx: Rx = .{},

        const Self = @This();

        /// Full raw response: `body` points into `rx.rx_buf` until the next `sendRaw` / `send`.
        pub const AtResponse = struct {
            status: AtStatus,
            body: []const u8,
            error_code: ?u16 = null,

            pub fn lineIterator(resp: AtResponse) LineIterator {
                return .{ .data = resp.body };
            }
        };

        pub const LineIterator = struct {
            data: []const u8,
            pos: usize = 0,

            pub fn next(it: *LineIterator) ?[]const u8 {
                if (it.pos >= it.data.len) return null;
                const rest = it.data[it.pos..];
                const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse {
                    const line = rest;
                    it.pos = it.data.len;
                    return trimTrailingCr(line);
                };
                const line = rest[0..nl];
                it.pos += nl + 1;
                return trimTrailingCr(line);
            }
        };

        pub fn init(io_instance: io.Io, time_v: Time) Self {
            return .{ .io_instance = io_instance, .time = time_v };
        }

        pub fn setIo(self: *Self, io_instance: io.Io) void {
            self.io_instance = io_instance;
        }

        /// Send raw bytes, read until OK / ERROR / +CME / +CMS or timeout.
        pub fn sendRaw(self: *Self, cmd: []const u8, timeout_ms: u32) AtResponse {
            self.rx.rx_len = 0;
            var woff: usize = 0;
            while (woff != cmd.len) {
                const nw = self.io_instance.write(cmd[woff..]) catch {
                    return .{ .status = .io_error, .body = &.{}, .error_code = null };
                };
                if (nw == 0) return .{ .status = .io_error, .body = &.{}, .error_code = null };
                woff += nw;
            }

            const t0 = self.time.nowMs();
            while (true) {
                if (self.rx.rx_len >= buf_size) {
                    return .{
                        .status = .overflow,
                        .body = self.rx.rx_buf[0..self.rx.rx_len],
                        .error_code = null,
                    };
                }
                if (self.time.nowMs() -| t0 >= timeout_ms) {
                    return .{
                        .status = .timeout,
                        .body = trimBodyEnd(self.rx.rx_buf[0..self.rx.rx_len]),
                        .error_code = null,
                    };
                }

                const n = self.io_instance.read(self.rx.rx_buf[self.rx.rx_len..]) catch |e| switch (e) {
                    error.WouldBlock => {
                        self.time.sleepMs(2);
                        continue;
                    },
                    else => return .{
                        .status = .io_error,
                        .body = trimBodyEnd(self.rx.rx_buf[0..self.rx.rx_len]),
                        .error_code = null,
                    },
                };
                self.rx.rx_len += n;

                if (parse.scanAtTerminal(self.rx.rx_buf[0..self.rx.rx_len])) |term| {
                    const body = trimBodyEnd(self.rx.rx_buf[0..term.body_end]);
                    const st: AtStatus = switch (term.kind) {
                        .ok => .ok,
                        .gen_error => .gen_error,
                        .cme_error => .cme_error,
                        .cms_error => .cms_error,
                    };
                    return .{
                        .status = st,
                        .body = body,
                        .error_code = term.error_code,
                    };
                }
            }
        }

        pub fn SendResult(comptime Cmd: type) type {
            if (Cmd.Response == void) {
                return struct {
                    status: AtStatus,
                    raw: AtResponse,
                };
            }
            return struct {
                status: AtStatus,
                raw: AtResponse,
                value: ?(Cmd.Response),
            };
        }

        pub fn send(self: *Self, comptime Cmd: type, cmd: anytype) SendResult(Cmd) {
            comptime {
                _ = Cmd.Response;
                _ = Cmd.prefix;
                _ = @as(u32, Cmd.timeout_ms);
                _ = @as(*const fn ([]u8) usize, &Cmd.write);
                _ = @as(*const fn ([]const u8) ?(Cmd.Response), &Cmd.parseResponse);
            }
            _ = cmd;

            var cmd_buf: [256]u8 = undefined;
            const cmd_len = Cmd.write(&cmd_buf);
            const raw = self.sendRaw(cmd_buf[0..cmd_len], Cmd.timeout_ms);

            if (Cmd.Response == void) {
                return .{ .status = raw.status, .raw = raw };
            }
            const val: ?(Cmd.Response) = if (raw.status == .ok)
                parse.parseTypedAtResponse(Cmd, raw.body)
            else
                null;
            return .{ .status = raw.status, .raw = raw, .value = val };
        }

        pub fn pumpUrcs(self: *Self) void {
            var scratch: [128]u8 = undefined;
            while (true) {
                const n = self.io_instance.read(&scratch) catch break;
                if (n == 0) break;
            }
        }
    };
}
