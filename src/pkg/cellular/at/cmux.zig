//! CMUX framing per 3GPP TS 27.010 (multiplexing over serial): multiplex AT and PPP over a single link.
//! Supports both protocol modes defined in 3GPP 27.010:
//! - **Advanced** (option 2): frame flag 0x7E, escape 0x7D, XOR FCS (aligned with GSM 07.10).
//! - **Basic** (option 1): frame flag 0xF9, no escape, CRC-8 FCS (common in esp_modem and many modems).
//! See plan.md §5.6 and R41. Step 9 implementation.

const std = @import("std");
const embed = @import("../../../mod.zig");
const io = @import("../io/io.zig");
const types = @import("../types.zig");

const SpawnConfig = embed.runtime.thread.SpawnConfig;

pub const FrameType = enum(u8) {
    sabm = 0x2F,
    ua = 0x63,
    dm = 0x0F,
    disc = 0x43,
    ui = 0x03,
    _,
};

/// CMUX frame (3GPP 27.010): DLCI, control byte, optional payload (UI/UIH).
pub const Frame = struct {
    dlci: u8,
    control: u8,
    data: []const u8,
};

// -----------------------------------------------------------------------------
// Advanced mode (3GPP TS 27.010 option 2 — flag 0x7E, escape, XOR FCS)
// -----------------------------------------------------------------------------

/// Advanced mode: frame start/end flag per 3GPP 27.010 (GSM 07.10).
const FLAG_ADVANCED: u8 = 0x7E;
/// Advanced mode: escape byte for 0x7E and 0x7D in payload/FCS.
const ESC_ADVANCED: u8 = 0x7D;
const ESC_MASK: u8 = 0x20;

// -----------------------------------------------------------------------------
// Basic mode (3GPP TS 27.010 option 1 — flag 0xF9, no escape, CRC-8 FCS)
// -----------------------------------------------------------------------------

/// Basic mode: frame start/end flag per 3GPP 27.010 option 1.
const FLAG_BASIC: u8 = 0xF9;

/// FCS for Advanced mode (3GPP 27.010): XOR of address, control, length, and info (unescaped).
pub fn calcFcsAdvanced(data: []const u8) u8 {
    var fcs: u8 = 0;
    for (data) |b| fcs ^= b;
    return fcs;
}

/// FCS for Basic mode (3GPP 27.010 option 1): CRC-8 over addr, ctrl, len_byte; FCS = 0xFF - crc.
pub fn calcFcsBasic(addr: u8, ctrl: u8, len_byte: u8) u8 {
    var crc: u8 = 0xFF;
    for ([_]u8{ addr, ctrl, len_byte }) |b| {
        crc ^= b;
        var j: u32 = 0;
        while (j < 8) : (j += 1) {
            if (crc & 1 != 0) {
                crc = (crc >> 1) ^ 0xE0;
            } else {
                crc >>= 1;
            }
        }
    }
    return 0xFF -% crc;
}

/// Encode one Advanced-mode frame (3GPP 27.010 option 2). Flag 0x7E, escape 0x7D, XOR FCS.
/// Returns bytes written or 0 if out too small. Length field 1 or 2 bytes per 27.010.
pub fn encodeFrameAdvanced(frame: Frame, out: []u8) usize {
    const addr: u8 = (frame.dlci << 2) | 0x03; // C/R=1 (command), EA=1
    const ctrl: u8 = frame.control;
    const info_len: usize = frame.data.len;
    if (info_len > 127) return 0;
    const len_byte: u8 = @intCast(info_len);

    var fcs_input: [131]u8 = undefined;
    fcs_input[0] = addr;
    fcs_input[1] = ctrl;
    fcs_input[2] = len_byte;
    @memcpy(fcs_input[3..][0..info_len], frame.data);
    const fcs = calcFcsAdvanced(fcs_input[0 .. 3 + info_len]);

    var n: usize = 0;
    if (out.len < 1) return 0;
    out[n] = FLAG_ADVANCED;
    n += 1;

    const to_escape = [_]u8{ addr, ctrl, len_byte };
    for (to_escape) |b| {
        if (n >= out.len) return 0;
        if (b == FLAG_ADVANCED or b == ESC_ADVANCED) {
            out[n] = ESC_ADVANCED;
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
        if (b == FLAG_ADVANCED or b == ESC_ADVANCED) {
            out[n] = ESC_ADVANCED;
            n += 1;
            out[n] = b ^ ESC_MASK;
            n += 1;
        } else {
            out[n] = b;
            n += 1;
        }
    }
    if (n + 2 > out.len) return 0;
    if (fcs == FLAG_ADVANCED or fcs == ESC_ADVANCED) {
        out[n] = ESC_ADVANCED;
        n += 1;
        out[n] = fcs ^ ESC_MASK;
        n += 1;
    } else {
        out[n] = fcs;
        n += 1;
    }
    out[n] = FLAG_ADVANCED;
    n += 1;
    return n;
}

/// Encode one Basic-mode frame (3GPP 27.010 option 1). Flag 0xF9, no escape, CRC-8 FCS.
/// Layout: F9 addr ctrl len [payload] fcs F9; length byte = (payload_len << 1) | 1 (EA).
pub fn encodeFrameBasic(frame: Frame, out: []u8) usize {
    if (out.len < 6) return 0;
    const addr: u8 = (frame.dlci << 2) | 0x03;
    const ctrl: u8 = frame.control;
    const info_len: usize = frame.data.len;
    if (info_len > 127) return 0;
    const len_byte: u8 = @intCast((info_len << 1) | 1);
    const fcs = calcFcsBasic(addr, ctrl, len_byte);
    out[0] = FLAG_BASIC;
    out[1] = addr;
    out[2] = ctrl;
    out[3] = len_byte;
    if (info_len > 0) {
        if (out.len < 6 + info_len + 2) return 0;
        @memcpy(out[4..][0..info_len], frame.data);
        out[4 + info_len] = fcs;
        out[5 + info_len] = FLAG_BASIC;
        return 6 + info_len;
    }
    out[4] = fcs;
    out[5] = FLAG_BASIC;
    return 6;
}

/// Decode one Basic-mode frame (3GPP 27.010 option 1). Data must start with 0xF9. Layout: F9 addr ctrl len [payload] fcs F9.
pub fn decodeFrameBasic(data: []const u8) ?Frame {
    if (data.len < 6 or data[0] != FLAG_BASIC) return null;
    const addr = data[1];
    const ctrl = data[2];
    const len_byte = data[3];
    const payload_len: usize = len_byte >> 1;
    if (data.len < 6 + payload_len) return null;
    const fcs_index = 4 + payload_len;
    if (data[fcs_index + 1] != FLAG_BASIC) return null;
    const fcs_received = data[fcs_index];
    const fcs_computed = calcFcsBasic(addr, ctrl, len_byte);
    if (fcs_received != fcs_computed) return null;
    const payload = if (payload_len > 0) data[4..][0..payload_len] else (&[_]u8{});
    return .{
        .dlci = (addr >> 2) & 0x3F,
        .control = ctrl,
        .data = payload,
    };
}

/// Decode one Advanced-mode frame (3GPP 27.010 option 2). Data must start with 0x7E.
/// data is modified in place for unescape; caller should pass a mutable copy if needed.
/// Supports 1- and 2-byte length (len_byte & 0x80) per 3GPP 27.010.
pub fn decodeFrameAdvanced(data: []u8) ?Frame {
    if (data.len < 4 or data[0] != FLAG_ADVANCED) return null;
    var i: usize = 1;
    var unescaped: [256]u8 = undefined;
    var u: usize = 0;
    while (i < data.len and data[i] != FLAG_ADVANCED) {
        if (data[i] == ESC_ADVANCED) {
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
    if (i >= data.len or data[i] != FLAG_ADVANCED) return null;
    const payload = unescaped[0..u];
    if (payload.len < 3) return null;
    const addr = payload[0];
    const ctrl = payload[1];
    const len_byte = payload[2];
    var info_len: usize = 0;
    var fcs_index: usize = 0;
    if (len_byte & 0x80 != 0) {
        if (payload.len < 4) return null;
        info_len = (@as(usize, len_byte & 0x7F) << 8) | payload[3];
        fcs_index = 4 + info_len;
    } else {
        info_len = @min(len_byte, 127);
        fcs_index = 3 + info_len;
    }
    if (payload.len < fcs_index + 1) return null;
    const info_start: usize = if (len_byte & 0x80 != 0) 4 else 3;
    const info_end: usize = info_start + info_len;
    const fcs_received = payload[fcs_index];
    const fcs_computed = calcFcsAdvanced(payload[0..fcs_index]);
    if (fcs_received != fcs_computed) return null;
    return .{
        .dlci = (addr >> 2) & 0x3F,
        .control = ctrl,
        .data = payload[info_start..info_end],
    };
}

/// Backward-compat alias: Advanced mode FCS (3GPP 27.010 option 2).
pub const calcFcs = calcFcsAdvanced;
/// Backward-compat alias: Advanced mode encode (3GPP 27.010 option 2).
pub const encodeFrame = encodeFrameAdvanced;
/// Backward-compat alias: Advanced mode decode (3GPP 27.010 option 2).
pub const decodeFrame = decodeFrameAdvanced;

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
        /// Single-frame read buffer for Advanced mode pump; avoids large stack allocation in pump task.
        adv_rx_buf: [max_frame_info + 16]u8 = undefined,
        rx_len: usize = 0,
        channels: [max_channels]ChannelBuf = [_]ChannelBuf{.{}} ** max_channels,
        notifiers: [max_channels]Notify = undefined,
        channel_ctxs: [max_channels]ChannelCtx = undefined,
        active: bool = false,
        pump_stop: bool = false,
        pump_handle: ?Thread = null,
        pump_sleep_ctx: ?*anyopaque = null,
        pump_sleep_ms: ?*const fn (*anyopaque, u32) void = null,
        open_sleep_ctx: ?*anyopaque = null,
        open_sleep_ms: ?*const fn (*anyopaque, u32) void = null,
        /// When true, use Basic mode (0xF9 + CRC FCS) for SABM/UA, as in esp_modem.
        open_use_basic: bool = false,
        /// After open: true if options.use_basic was set; pump/write/close use Basic encoding.
        basic_mode: bool = false,

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

        /// For debug: current rx buffer content (e.g. on open timeout).
        pub fn getRxBuf(self: *Self) []const u8 {
            return self.rx_buf[0..self.rx_len];
        }

        /// Caller must have sent AT+CMUX=0 before calling. Opens DLCIs with SABM/UA.
        /// Pass options.sleep_ctx and options.sleep_ms (e.g. modem) for 10ms yield in UA wait; pass .{} in tests.
        /// options.use_basic: use Basic mode (0xF9 + CRC FCS) as esp_modem; try this if Advanced (0x7E) gets no UA.
        pub fn open(self: *Self, dlcis: []const u8, options: struct {
            sleep_ctx: ?*anyopaque = null,
            sleep_ms: ?*const fn (*anyopaque, u32) void = null,
            use_basic: bool = false,
        }) OpenError!void {
            self.open_sleep_ctx = options.sleep_ctx;
            self.open_sleep_ms = options.sleep_ms;
            self.open_use_basic = options.use_basic;
            self.basic_mode = options.use_basic;
            defer {
                self.open_sleep_ctx = null;
                self.open_sleep_ms = null;
                self.open_use_basic = false;
            }
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
                const n = encodeFrameAdvanced(frame, &frame_buf);
                _ = self.io.*.write(frame_buf[0..n]) catch {};
                self.channels[d].open = true;
            }
            self.active = true;
        }

        fn sendSabmAndWaitUa(self: *Self, dlci: u8) OpenError!void {
            var frame_buf: [32]u8 = undefined;
            const sabm_ctl = if (self.open_use_basic) 0x3F else @intFromEnum(FrameType.sabm);
            const frame = Frame{ .dlci = dlci, .control = sabm_ctl, .data = &.{} };
            const n = if (self.open_use_basic)
                encodeFrameBasic(frame, &frame_buf)
            else
                encodeFrameAdvanced(frame, &frame_buf);
            _ = self.io.*.write(frame_buf[0..n]) catch return error.PeerRejected;
            const max_iter: u32 = if (self.open_sleep_ms != null) 500 else 50;
            for (0..max_iter) |_| {
                const r = self.io.*.read(self.rx_buf[self.rx_len..]) catch {
                    if (self.open_sleep_ms) |sfn| {
                        if (self.open_sleep_ctx) |ctx| sfn(ctx, 10);
                    }
                    continue;
                };
                if (r > 0) self.rx_len += r;
                while (self.rx_len > 0 and self.rx_buf[0] != FLAG_ADVANCED and self.rx_buf[0] != FLAG_BASIC) {
                    self.rx_len -= 1;
                    std.mem.copyForwards(u8, self.rx_buf[0..self.rx_len], self.rx_buf[1..][0..self.rx_len]);
                }
                while (self.rx_len >= 2 and (self.rx_buf[0] == FLAG_ADVANCED or self.rx_buf[0] == FLAG_BASIC)) {
                    const is_basic = self.rx_buf[0] == FLAG_BASIC;
                    const end_marker: u8 = if (is_basic) FLAG_BASIC else FLAG_ADVANCED;
                    var end: usize = 1;
                    while (end < self.rx_len and self.rx_buf[end] != end_marker) end += 1;
                    if (end >= self.rx_len) break;
                    const frame_len = end + 1;
                    const copy_len = @min(frame_len, self.rx_buf.len);
                    if (is_basic) {
                        const slice = self.rx_buf[0..frame_len];
                        if (decodeFrameBasic(slice)) |dec| {
                            if (dec.dlci == dlci and (dec.control & 0xEF) == @intFromEnum(FrameType.ua)) return;
                            if (dec.control == @intFromEnum(FrameType.dm)) return error.PeerRejected;
                        }
                    } else {
                        var copy: [256]u8 = undefined;
                        @memcpy(copy[0..copy_len], self.rx_buf[0..copy_len]);
                        if (decodeFrameAdvanced(copy[0..copy_len])) |dec| {
                            if (dec.dlci == dlci and dec.control == @intFromEnum(FrameType.ua)) return;
                            if (dec.control == @intFromEnum(FrameType.dm)) return error.PeerRejected;
                        }
                    }
                    const remain = self.rx_len - frame_len;
                    if (remain > 0) {
                        std.mem.copyForwards(u8, self.rx_buf[0..remain], self.rx_buf[frame_len..][0..remain]);
                    }
                    self.rx_len = remain;
                }
                if (self.open_sleep_ms) |sfn| {
                    if (self.open_sleep_ctx) |ctx| sfn(ctx, 10);
                }
            }
            return error.Timeout;
        }

        /// Send DISC and mark channels closed. Caller must ensure the pump has already stopped
        /// (e.g. after stopPump() and a delay >= io.read() timeout); otherwise concurrent access to
        /// self.channels from the pump may race.
        pub fn close(self: *Self) void {
            self.active = false;
            for (0..max_channels) |i| {
                if (self.channels[i].open) {
                    var frame_buf: [32]u8 = undefined;
                    const frame = Frame{ .dlci = @intCast(i), .control = @intFromEnum(FrameType.disc), .data = &.{} };
                    const n = if (self.basic_mode) encodeFrameBasic(frame, &frame_buf) else encodeFrameAdvanced(frame, &frame_buf);
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
            var n = ch.cmux.channels[ch.dlci].pull(buf);
            if (n == 0) {
                ch.cmux.pump();
                n = ch.cmux.channels[ch.dlci].pull(buf);
            }
            if (n == 0) return error.WouldBlock;
            return n;
        }
        fn writeChannel(ctx: *anyopaque, buf: []const u8) io.IoError!usize {
            const ch = @as(*ChannelCtx, @ptrCast(@alignCast(ctx)));
            if (buf.len > 127) return error.IoError;
            var frame_buf: [256]u8 = undefined;
            const ctrl = if (ch.cmux.basic_mode) 0xEF else @intFromEnum(FrameType.ui);
            const frame = Frame{
                .dlci = ch.dlci,
                .control = ctrl,
                .data = buf,
            };
            const n = if (ch.cmux.basic_mode) encodeFrameBasic(frame, &frame_buf) else encodeFrameAdvanced(frame, &frame_buf);
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

        /// One demux iteration. Returns immediately if pump_stop is set so teardown can complete without
        /// entering a blocking read.
        pub fn pump(self: *Self) void {
            if (self.pump_stop) return;
            if (self.basic_mode) {
                const r = self.io.*.read(self.rx_buf[self.rx_len..]) catch return;
                if (r > 0) self.rx_len += r;
                while (self.rx_len > 0 and self.rx_buf[0] != FLAG_BASIC) {
                    self.rx_len -= 1;
                    std.mem.copyForwards(u8, self.rx_buf[0..self.rx_len], self.rx_buf[1..][0..self.rx_len]);
                }
                while (self.rx_len >= 6 and self.rx_buf[0] == FLAG_BASIC) {
                    var end: usize = 1;
                    while (end < self.rx_len and self.rx_buf[end] != FLAG_BASIC) end += 1;
                    if (end >= self.rx_len) break;
                    const frame_len = end + 1;
                    const slice = self.rx_buf[0..frame_len];
                    if (decodeFrameBasic(slice)) |dec| {
                        if (dec.dlci < max_channels and self.channels[dec.dlci].open) {
                            self.channels[dec.dlci].push(dec.data);
                            (&self.notifiers[dec.dlci]).signal();
                        }
                    }
                    self.rx_len -= frame_len;
                    if (self.rx_len > 0) {
                        std.mem.copyForwards(u8, self.rx_buf[0..self.rx_len], self.rx_buf[frame_len..][0..self.rx_len]);
                    }
                }
                return;
            }
            const n = self.io.*.read(self.adv_rx_buf[0..]) catch return;
            if (n == 0) return;
            if (decodeFrameAdvanced(self.adv_rx_buf[0..n])) |dec| {
                if (dec.dlci < max_channels and self.channels[dec.dlci].open) {
                    self.channels[dec.dlci].push(dec.data);
                    (&self.notifiers[dec.dlci]).signal();
                }
            }
        }

        fn pumpLoop(ctx: ?*anyopaque) void {
            const self_ptr: *Self = @ptrCast(@alignCast(ctx.?));
            while (!self_ptr.pump_stop) {
                self_ptr.pump();
                if (self_ptr.pump_sleep_ctx) |sctx| {
                    if (self_ptr.pump_sleep_ms) |sfn| sfn(sctx, 10);
                } else if (comptime @import("builtin").os.tag != .freestanding) {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                }
            }
        }

        /// Start the pump task. Pass optional spawn_config for allocator/stack and sleep (e.g. on ESP use sleep_ms instead of std.Thread.sleep).
        pub fn startPump(self: *Self, spawn_config: ?SpawnConfig) !void {
            self.pump_stop = false;
            const config = spawn_config orelse SpawnConfig{};
            self.pump_sleep_ctx = config.sleep_ctx;
            self.pump_sleep_ms = config.sleep_ms;
            const handle = try Thread.spawn(config, pumpLoop, self);
            self.pump_handle = handle;
        }
        /// Stops the pump task without join to avoid racing with FreeRTOS idle's prvDeleteTCB
        /// (join+free in esp-zig runtime can cause StoreProhibited). Sets pump_stop and detaches.
        /// Caller must then sleep for at least the underlying io.read() timeout (e.g. modem uses
        /// cmux_pump_exit_delay_ms) so the pump can leave io.read(), see pump_stop, and exit before
        /// close() and cmux=null; otherwise the pump may touch deallocated Cmux/modem stack → LoadProhibited.
        pub fn stopPump(self: *Self) void {
            self.pump_stop = true;
            if (self.pump_handle) |*h| {
                h.detach();
                self.pump_handle = null;
            }
        }
    };
}

pub fn CmuxType(comptime Thread: type, comptime Notify: type, comptime max_channels: u8) type {
    return Cmux(Thread, Notify, max_channels);
}
