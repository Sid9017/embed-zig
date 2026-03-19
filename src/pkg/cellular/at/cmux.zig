//! GSM 07.10 CMUX framing: multiplex AT and PPP over a single serial link.
//! See plan.md §5.6 and R41. Step 9 implementation.

const io = @import("../io/io.zig");
const types = @import("../types.zig");

pub const FrameType = enum(u8) {
    sabm = 0x2F,
    ua = 0x63,
    dm = 0x0F,
    disc = 0x43,
    ui = 0x03,
    _,
};

/// GSM 07.10 frame: DLCI, control byte, optional payload (UI frames).
pub const Frame = struct {
    dlci: u8,
    control: u8,
    data: []const u8,
};

const FLAG: u8 = 0x7E;
const ESC: u8 = 0x7D;
const ESC_MASK: u8 = 0x20;

/// FCS per GSM 07.10: XOR of address, control, length, and info (unescaped).
pub fn calcFcs(data: []const u8) u8 {
    var fcs: u8 = 0;
    for (data) |b| fcs ^= b;
    return fcs;
}

/// Encode frame into out; returns bytes written or 0 if out too small.
/// Uses 1-byte length field (info 0..127). Escapes 0x7E and 0x7D in info and FCS.
pub fn encodeFrame(frame: Frame, out: []u8) usize {
    const addr: u8 = (frame.dlci << 2) | 0x03; // C/R=1 (command), EA=1
    const ctrl: u8 = frame.control;
    const info_len: usize = frame.data.len;
    if (info_len > 127) return 0;
    const len_byte: u8 = @intCast(info_len);

    // Unescaped payload for FCS: address, control, length, info
    var fcs_input: [131]u8 = undefined; // 1+1+1+127 max
    fcs_input[0] = addr;
    fcs_input[1] = ctrl;
    fcs_input[2] = len_byte;
    @memcpy(fcs_input[3..][0..info_len], frame.data);
    const fcs = calcFcs(fcs_input[0 .. 3 + info_len]);

    var n: usize = 0;
    if (out.len < 1) return 0;
    out[n] = FLAG;
    n += 1;

    const to_escape = [_]u8{ addr, ctrl, len_byte };
    for (to_escape) |b| {
        if (n >= out.len) return 0;
        if (b == FLAG or b == ESC) {
            out[n] = ESC;
            n += 1;
            if (n >= out.len) return 0;
            out[n] = b ^ ESC_MASK;
            n += 1;
        } else {
            out[n] = b;
            n += 1;
        }
    }
    for (frame.data) |b| {
        if (n + 2 > out.len) return 0;
        if (b == FLAG or b == ESC) {
            out[n] = ESC;
            n += 1;
            out[n] = b ^ ESC_MASK;
            n += 1;
        } else {
            out[n] = b;
            n += 1;
        }
    }
    if (n + 2 > out.len) return 0;
    if (fcs == FLAG or fcs == ESC) {
        out[n] = ESC;
        n += 1;
        out[n] = fcs ^ ESC_MASK;
        n += 1;
    } else {
        out[n] = fcs;
        n += 1;
    }
    out[n] = FLAG;
    n += 1;
    return n;
}

/// Decode one frame from data (must start with 0x7E); returns Frame or null.
/// data is modified in place for unescape; caller should pass a mutable copy if needed.
pub fn decodeFrame(data: []u8) ?Frame {
    if (data.len < 4 or data[0] != FLAG) return null;
    var i: usize = 1;
    var unescaped: [256]u8 = undefined;
    var u: usize = 0;
    while (i < data.len and data[i] != FLAG) {
        if (data[i] == ESC) {
            i += 1;
            if (i >= data.len) return null;
            unescaped[u] = data[i] ^ ESC_MASK;
            u += 1;
            i += 1;
        } else {
            unescaped[u] = data[i];
            u += 1;
            i += 1;
        }
        if (u >= unescaped.len) return null;
    }
    if (i >= data.len or data[i] != FLAG) return null;
    const payload = unescaped[0..u];
    if (payload.len < 3) return null;
    const addr = payload[0];
    const ctrl = payload[1];
    const len_byte = payload[2];
    const dlci = (addr >> 2) & 0x3F;
    const info_len: usize = @min(len_byte, 127);
    if (payload.len < 3 + info_len + 1) return null;
    const info_start: usize = 3;
    const info_end: usize = info_start + info_len;
    const fcs_received = payload[info_end];
    const fcs_computed = calcFcs(payload[0..info_end]);
    if (fcs_received != fcs_computed) return null;
    return .{
        .dlci = dlci,
        .control = ctrl,
        .data = payload[info_start..info_end],
    };
}

/// Cmux errors for open() (timeout, peer sent DM, etc.).
pub const OpenError = error{ Timeout, PeerRejected };


/// Max size of one decoded frame payload we accept.
pub const max_frame_info: usize = 256;

fn Cmux(
    comptime Thread: type,
    comptime Notify: type,
    comptime max_channels: u8,
) type {
    return struct {
        const Self = @This();
        const ChannelBuf = struct {
            buf: [512]u8 = undefined,
            read_pos: usize = 0,
            write_pos: usize = 0,
            open: bool = false,

            fn push(self: *ChannelBuf, data: []const u8) void {
                for (data) |b| {
                    self.buf[self.write_pos % self.buf.len] = b;
                    self.write_pos += 1;
                }
            }

            fn pull(self: *ChannelBuf, out: []u8) usize {
                var n: usize = 0;
                while (n < out.len and self.read_pos < self.write_pos) {
                    out[n] = self.buf[self.read_pos % self.buf.len];
                    n += 1;
                    self.read_pos += 1;
                }
                return n;
            }
        };

        pub const ChannelCtx = struct {
            cmux: *Self = undefined,
            dlci: u8 = 0,
        };

        io: *const io.Io,
        rx_buf: [256]u8 = undefined,
        rx_len: usize = 0,
        channels: [max_channels]ChannelBuf = [_]ChannelBuf{.{}} ** max_channels,
        notifiers: [max_channels]Notify = undefined,
        channel_ctxs: [max_channels]ChannelCtx = undefined,
        active: bool = false,
        pump_stop: bool = false,
        pump_handle: ?Thread = null,

        pub fn init(io_instance: *const io.Io, notifiers_init: [max_channels]Notify) Self {
            var s: Self = .{
                .io = io_instance,
                .notifiers = notifiers_init,
            };
            for (0..max_channels) |i| {
                s.channel_ctxs[i] = .{ .dlci = @intCast(i) };
            }
            return s;
        }

        /// Caller must have sent AT+CMUX=0 before calling. Opens DLCIs with SABM/UA.
        pub fn open(self: *Self, dlcis: []const u8) OpenError!void {
            for (dlcis) |d| {
                if (d >= max_channels) return error.PeerRejected;
                try self.sendSabmAndWaitUa(d);
                self.channels[d].open = true;
            }
            self.active = true;
        }

        /// Test-only: send SABM for each DLCI and mark channels open without waiting for UA.
        /// Use open() in production so the peer can respond with UA.
        pub fn openWithoutHandshake(self: *Self, dlcis: []const u8) void {
            for (dlcis) |d| {
                if (d >= max_channels) continue;
                var frame_buf: [32]u8 = undefined;
                const frame = Frame{ .dlci = d, .control = @intFromEnum(FrameType.sabm), .data = &.{} };
                const n = encodeFrame(frame, &frame_buf);
                _ = self.io.*.write(frame_buf[0..n]) catch {};
                self.channels[d].open = true;
            }
            self.active = true;
        }

        fn sendSabmAndWaitUa(self: *Self, dlci: u8) OpenError!void {
            var frame_buf: [32]u8 = undefined;
            const frame = Frame{ .dlci = dlci, .control = @intFromEnum(FrameType.sabm), .data = &.{} };
            const n = encodeFrame(frame, &frame_buf);
            _ = self.io.*.write(frame_buf[0..n]) catch return error.PeerRejected;
            for (0..50) |_| {
                const r = self.io.*.read(self.rx_buf[self.rx_len..]) catch continue;
                if (r > 0) self.rx_len += r;
                while (self.rx_len >= 2 and self.rx_buf[0] == FLAG) {
                    var end: usize = 1;
                    while (end < self.rx_len and self.rx_buf[end] != FLAG) end += 1;
                    if (end >= self.rx_len) break;
                    const frame_len = end + 1;
                    var copy: [256]u8 = undefined;
                    const copy_len = @min(frame_len, copy.len);
                    @memcpy(copy[0..copy_len], self.rx_buf[0..copy_len]);
                    if (decodeFrame(copy[0..copy_len])) |dec| {
                        const remain = self.rx_len - frame_len;
                        var tmp: [256]u8 = undefined;
                        if (remain > 0) {
                            @memcpy(tmp[0..remain], self.rx_buf[frame_len..][0..remain]);
                            @memcpy(self.rx_buf[0..remain], tmp[0..remain]);
                        }
                        self.rx_len = remain;
                        if (dec.dlci == dlci and dec.control == @intFromEnum(FrameType.ua)) return;
                        if (dec.control == @intFromEnum(FrameType.dm)) return error.PeerRejected;
                    } else break;
                }
            }
            return error.Timeout;
        }

        pub fn close(self: *Self) void {
            self.active = false;
            for (0..max_channels) |i| {
                if (self.channels[i].open) {
                    var frame_buf: [32]u8 = undefined;
                    const frame = Frame{ .dlci = @intCast(i), .control = @intFromEnum(FrameType.disc), .data = &.{} };
                    const n = encodeFrame(frame, &frame_buf);
                    _ = self.io.*.write(frame_buf[0..n]) catch {};
                    self.channels[i].open = false;
                }
            }
        }

        pub fn channelIo(self: *Self, dlci: u8) ?io.Io {
            if (dlci >= max_channels or !self.channels[dlci].open) return null;
            self.channel_ctxs[dlci].cmux = self;
            self.channel_ctxs[dlci].dlci = dlci;
            return .{
                .ctx = &self.channel_ctxs[dlci],
                .readFn = readChannel,
                .writeFn = writeChannel,
                .pollFn = pollChannel,
            };
        }

        fn readChannel(ctx: *anyopaque, buf: []u8) io.IoError!usize {
            const ch = @as(*ChannelCtx, @ptrCast(@alignCast(ctx)));
            const n = ch.cmux.channels[ch.dlci].pull(buf);
            if (n == 0) return error.WouldBlock;
            return n;
        }
        fn writeChannel(ctx: *anyopaque, buf: []const u8) io.IoError!usize {
            const ch = @as(*ChannelCtx, @ptrCast(@alignCast(ctx)));
            if (buf.len > 127) return error.IoError;
            var frame_buf: [256]u8 = undefined;
            const frame = Frame{
                .dlci = ch.dlci,
                .control = @intFromEnum(FrameType.ui),
                .data = buf,
            };
            const n = encodeFrame(frame, &frame_buf);
            const w = ch.cmux.io.*.write(frame_buf[0..n]) catch return error.IoError;
            if (w != n) return error.IoError;
            return buf.len;
        }
        fn pollChannel(ctx: *anyopaque, timeout_ms: i32) io.PollFlags {
            const ch = @as(*ChannelCtx, @ptrCast(@alignCast(ctx)));
            const timeout_ns: u64 = if (timeout_ms <= 0) 0 else @as(u64, @intCast(timeout_ms)) * 1_000_000;
            const notifier = &ch.cmux.notifiers[ch.dlci];
            const signaled = notifier.timedWait(timeout_ns);
            return .{ .readable = signaled, .writable = true };
        }

        pub fn pump(self: *Self) void {
            var rx: [max_frame_info + 16]u8 = undefined;
            const n = self.io.*.read(rx[0..]) catch return;
            if (n == 0) return;
            if (decodeFrame(rx[0..n])) |dec| {
                if (dec.dlci < max_channels and self.channels[dec.dlci].open) {
                    self.channels[dec.dlci].push(dec.data);
                    (&self.notifiers[dec.dlci]).signal();
                }
            }
        }

        pub fn startPump(self: *Self) !void {
            _ = self;
        }
        pub fn stopPump(self: *Self) void {
            self.pump_stop = true;
        }
    };
}

pub fn CmuxType(comptime Thread: type, comptime Notify: type, comptime max_channels: u8) type {
    return Cmux(Thread, Notify, max_channels);
}
