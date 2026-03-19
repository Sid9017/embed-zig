//! Modem hardware driver: owns Io/AtEngine, provides SIM/IMEI/signal queries.
//! See plan.md §5.7. No state machine — that lives in cellular.zig.

const std = @import("std");
const embed = @import("../../../mod.zig");
const types = @import("../types.zig");
const io = @import("../io/io.zig");
const engine = @import("../at/engine.zig");
const commands = @import("../at/commands.zig");
const cmux_mod = @import("../at/cmux.zig");
const thread = embed.runtime.thread;

pub fn Modem(
    comptime Thread: type,
    comptime Notify: type,
    comptime Time: type,
    comptime Module: type,
    comptime Gpio: type,
    comptime at_buf_size: usize,
) type {
    comptime {
        _ = @as(*const fn (thread.SpawnConfig, thread.TaskFn, ?*anyopaque) anyerror!Thread, &Thread.spawn);
        _ = Notify.init;
        _ = Module.commands;
        _ = Module.urcs;
        _ = Module.init_sequence;
    }
    const At = engine.AtEngine(Time, at_buf_size);
    return struct {
        const Self = @This();

        /// Init fails when neither io nor at_io is provided (plan Step 8 / MD-03),
        /// or when single-channel and config.cmux_channels is invalid (Step 10 / R41).
        pub const InitError = error{ NoIo, InvalidCmuxConfig };

        pub const MODEM_CMUX_MAX_CHANNELS: u8 = 4;

        pub const PowerPins = struct {
            power_pin: ?u8 = null,
            reset_pin: ?u8 = null,
            vint_pin: ?u8 = null,
        };

        pub const InitConfig = struct {
            io: ?io.Io = null,
            at_io: ?io.Io = null,
            data_io: ?io.Io = null,
            time: Time,
            gpio: ?*Gpio = null,
            pins: PowerPins = .{},
            set_rate: ?*const fn (u32) anyerror!void = null,
            config: types.ModemConfig = .{},
            /// Optional spawn config for CMUX pump task (e.g. allocator on ESP). Single-channel only.
            /// Use stack_size >= 8192 on ESP; pump calls io.read/BSP and overflow corrupts heap,
            /// causing StoreProhibited in idle when FreeRTOS frees the task stack after exitCmux.
            pump_spawn_config: ?thread.SpawnConfig = null,
        };

        at_engine: At = undefined,
        time: Time = undefined,
        data_io: ?io.Io = null,
        config: types.ModemConfig = .{},
        /// Single-channel only: raw Io saved at init for exitCmux restore (Step 10).
        raw_io: io.Io = undefined,
        /// Notifiers for Cmux; inited in init when single-channel.
        notifiers: [MODEM_CMUX_MAX_CHANNELS]Notify = undefined,
        /// Single-channel CMUX session; non-null when isCmuxActive().
        cmux: ?cmux_mod.CmuxType(Thread, Notify, MODEM_CMUX_MAX_CHANNELS) = null,
        /// Spawn config for CMUX pump (single-channel); from InitConfig.
        pump_spawn_config: ?thread.SpawnConfig = null,
        sim_info: types.SimInfo = .{},
        modem_info: types.ModemInfo = .{},
        last_signal: ?types.CellularSignalInfo = null,
        cmux_debug_buf: [128]u8 = undefined,

        pub fn init(cfg: InitConfig) InitError!Self {
            const at_io: io.Io = blk: {
                if (cfg.at_io) |x| break :blk x;
                if (cfg.io) |x| break :blk x;
                return error.NoIo;
            };
            if (cfg.data_io == null) {
                validateCmuxConfig(cfg.config) catch return error.InvalidCmuxConfig;
            }
            var notifiers: [MODEM_CMUX_MAX_CHANNELS]Notify = undefined;
            for (&notifiers) |*n| n.* = Notify.init();
            return .{
                .at_engine = At.init(at_io, cfg.time),
                .time = cfg.time,
                .data_io = cfg.data_io,
                .config = cfg.config,
                .raw_io = at_io,
                .notifiers = notifiers,
                .pump_spawn_config = cfg.pump_spawn_config,
            };
        }

        fn validateCmuxConfig(config: types.ModemConfig) InitError!void {
            const ch = config.cmux_channels;
            if (ch.len == 0 or ch.len > MODEM_CMUX_MAX_CHANNELS) return error.InvalidCmuxConfig;
            var has_at: bool = false;
            var seen: [MODEM_CMUX_MAX_CHANNELS]bool = [_]bool{false} ** MODEM_CMUX_MAX_CHANNELS;
            for (ch) |c| {
                if (c.dlci >= MODEM_CMUX_MAX_CHANNELS) return error.InvalidCmuxConfig;
                if (seen[c.dlci]) return error.InvalidCmuxConfig;
                seen[c.dlci] = true;
                switch (c.role) {
                    .at => has_at = true,
                    .ppp => {},
                }
            }
            if (!has_at) return error.InvalidCmuxConfig;
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn at(self: *Self) *At {
            return &self.at_engine;
        }

        pub fn pppIo(self: *Self) ?io.Io {
            if (self.data_io != null) return self.data_io;
            if (self.cmux) |*c| {
                const ppp_dlci = dlciForRole(self.config, .ppp) orelse return null;
                return c.channelIo(ppp_dlci);
            }
            return null;
        }

        /// single_channel when data_io is null; multi_channel when data_io is provided (plan Step 8).
        pub fn mode(self: *const Self) enum { single_channel, multi_channel } {
            return if (self.data_io != null) .multi_channel else .single_channel;
        }

        pub fn isCmuxActive(self: *const Self) bool {
            if (self.cmux) |*c| return c.active;
            return false;
        }

        /// Used by CMUX pump loop on freestanding (no std.Thread.sleep); ctx = *Self.
        pub fn pumpSleepMs(ctx: *anyopaque, ms: u32) void {
            const self_ptr: *Self = @ptrCast(@alignCast(ctx));
            self_ptr.time.sleepMs(ms);
        }

        /// Result of enterCmux: ok or err with AT response (for logging).
        pub const EnterCmuxResult = union(enum) {
            ok,
            err: struct {
                status: engine.AtStatus,
                body: []const u8,
            },
        };

        /// Single-channel: AT+CMUX=0 then SABM/UA, set at_engine Io to AT channel, start pump.
        pub fn enterCmux(self: *Self) EnterCmuxResult {
            if (self.data_io != null) return .ok;
            const at_dlci = dlciForRole(self.config, .at) orelse return .{
                .err = .{ .status = .gen_error, .body = "InvalidCmuxConfig" },
            };
            var dlcis_buf: [MODEM_CMUX_MAX_CHANNELS]u8 = undefined;
            var dlcis_len: usize = 0;
            for (self.config.cmux_channels) |c| {
                if (dlcis_len < MODEM_CMUX_MAX_CHANNELS) {
                    dlcis_buf[dlcis_len] = c.dlci;
                    dlcis_len += 1;
                }
            }
            const cmux_timeout_ms = @max(self.config.at_timeout_ms, 8000);
            const resp = self.at_engine.sendRaw("AT+CMUX=0\r\n", cmux_timeout_ms);
            if (resp.status != .ok) return .{
                .err = .{ .status = resp.status, .body = resp.body },
            };
            self.time.sleepMs(80);
            var drain_buf: [64]u8 = undefined;
            for (0..5) |_| {
                _ = self.raw_io.read(&drain_buf) catch {};
                self.time.sleepMs(10);
            }
            self.cmux = cmux_mod.CmuxType(Thread, Notify, MODEM_CMUX_MAX_CHANNELS).init(&self.raw_io, self.notifiers);
            self.cmux.?.open(dlcis_buf[0..dlcis_len], .{
                .sleep_ctx = self,
                .sleep_ms = Self.pumpSleepMs,
                .use_basic = self.config.use_basic_cmux,
            }) catch |open_err| {
                const msg: []const u8 = switch (open_err) {
                    error.Timeout => blk: {
                        const rx = self.cmux.?.getRxBuf();
                        var n = (std.fmt.bufPrint(&self.cmux_debug_buf, "timeout (no UA); rx {d} bytes", .{rx.len}) catch self.cmux_debug_buf[0..0]).len;
                        if (rx.len > 0 and n + 80 < self.cmux_debug_buf.len) {
                            self.cmux_debug_buf[n] = ':';
                            n += 1;
                            const hex = "0123456789ABCDEF";
                            const show = @min(rx.len, 24);
                            for (rx[0..show]) |b| {
                                if (n + 3 > self.cmux_debug_buf.len) break;
                                self.cmux_debug_buf[n] = ' ';
                                self.cmux_debug_buf[n + 1] = hex[b >> 4];
                                self.cmux_debug_buf[n + 2] = hex[b & 0x0F];
                                n += 3;
                            }
                        }
                        break :blk self.cmux_debug_buf[0..n];
                    },
                    error.PeerRejected => "cmux open failed: peer rejected (DM or invalid)",
                };
                self.cmux.?.close(); // close any DLCIs opened before the failure; pump not started
                self.cmux = null;
                return .{ .err = .{ .status = .gen_error, .body = msg } };
            };
            self.at_engine.setIo(self.cmux.?.channelIo(at_dlci) orelse {
                self.cmux.?.close(); // safe: pump not started yet
                self.cmux = null;
                return .{ .err = .{ .status = .gen_error, .body = "channelIo null" } };
            });
            if (!self.config.use_main_thread_pump) {
                var pump_cfg = self.pump_spawn_config orelse thread.SpawnConfig{};
                pump_cfg.sleep_ctx = self;
                pump_cfg.sleep_ms = Self.pumpSleepMs;
                self.cmux.?.startPump(pump_cfg) catch {
                    self.cmux.?.close(); // safe: pump not started (spawn failed)
                    self.at_engine.setIo(self.raw_io);
                    self.cmux = null;
                    return .{ .err = .{ .status = .gen_error, .body = "startPump failed" } };
                };
            }
            return .ok;
        }

        /// Delay (ms) after stopPump() before close/setIo/null. Must be >= underlying UART read timeout
        /// so the pump can leave io.read(), see pump_stop, and exit before Cmux/modem stack is torn down.
        pub const cmux_pump_exit_delay_ms: u32 = 500;

        /// Single-channel: stop pump, close CMUX, restore at_engine to raw Io.
        ///
        /// **Teardown order (avoids use-after-free / LoadProhibited):**
        /// 1. stopPump() — set pump_stop, detach (pump may still be blocked in io.read()).
        /// 2. sleep(cmux_pump_exit_delay_ms) — allow pump to leave read() and exit; Cmux is still valid.
        /// 3. close() — send DISC, set active=false and channels[].open=false (call only after pump has stopped).
        /// 4. setIo(raw_io) — at_engine no longer uses channel Io (no more readChannel/writeChannel).
        /// 5. cmux = null — drop reference; modem stack remains valid until run() returns.
        /// The pump task holds ctx = &cmux; if it runs after (5) and run() has returned, modem stack is gone → crash.
        /// So the delay must be long enough that the pump exits before we return from exitCmux.
        pub fn exitCmux(self: *Self) void {
            if (self.cmux) |*c| {
                if (c.pump_handle != null) {
                    c.stopPump();
                    self.time.sleepMs(Self.cmux_pump_exit_delay_ms);
                }
                c.close();
                self.at_engine.setIo(self.raw_io);
                self.cmux = null;
            }
        }

        /// When CMUX active, call once to demux one batch (tests / single-threaded). No-op if no pump thread.
        pub fn pump(self: *Self) void {
            if (self.cmux) |*c| c.pump();
        }

        fn dlciForRole(config: types.ModemConfig, role: types.CmuxChannelRole) ?u8 {
            for (config.cmux_channels) |c| {
                if (c.role == role) return c.dlci;
            }
            return null;
        }

        // ----- SIM queries -----

        /// Sends AT+CPIN? and returns the SIM status.
        pub fn getSimStatus(self: *Self) !types.SimStatus {
            const result = self.at_engine.send(commands.GetCpin, {});
            switch (result.status) {
                .timeout => return error.Timeout,
                .ok => {},
                else => return error.AtError,
            }
            const status = result.value orelse return error.ParseError;
            self.sim_info.status = status;
            return status;
        }

        /// Sends AT+CIMI and returns the IMSI string (stored in internal buffer).
        pub fn getImsi(self: *Self) ![]const u8 {
            const result = self.at_engine.send(commands.GetImsi, {});
            switch (result.status) {
                .timeout => return error.Timeout,
                .ok => {},
                else => return error.AtError,
            }
            const imsi = result.value orelse return error.ParseError;
            if (imsi.len > types.BufferLen.imsi) return error.ParseError;
            @memcpy(self.sim_info.imsi[0..imsi.len], imsi);
            self.sim_info.imsi_len = @intCast(imsi.len);
            return self.sim_info.imsi[0..self.sim_info.imsi_len];
        }

        /// Sends AT+CCID and returns the ICCID string (stored in internal buffer).
        pub fn getIccid(self: *Self) ![]const u8 {
            const result = self.at_engine.send(commands.GetIccid, {});
            switch (result.status) {
                .timeout => return error.Timeout,
                .ok => {},
                else => return error.AtError,
            }
            const iccid = result.value orelse return error.ParseError;
            if (iccid.len > types.BufferLen.iccid) return error.ParseError;
            @memcpy(self.sim_info.iccid[0..iccid.len], iccid);
            self.sim_info.iccid_len = @intCast(iccid.len);
            return self.sim_info.iccid[0..self.sim_info.iccid_len];
        }

        /// Sends AT+CGSN and returns the IMEI string (stored in internal buffer).
        pub fn getImei(self: *Self) ![]const u8 {
            const result = self.at_engine.send(commands.GetImei, {});
            switch (result.status) {
                .timeout => return error.Timeout,
                .ok => {},
                else => return error.AtError,
            }
            const imei = result.value orelse return error.ParseError;
            if (imei.len > types.BufferLen.imei) return error.ParseError;
            @memcpy(self.modem_info.imei[0..imei.len], imei);
            self.modem_info.imei_len = @intCast(imei.len);
            return self.modem_info.imei[0..self.modem_info.imei_len];
        }

        // ----- Signal queries -----

        /// Sends AT+CSQ and returns signal info. Caches the result.
        pub fn getSignal(self: *Self) !types.CellularSignalInfo {
            const out = self.at_engine.send(commands.GetSignalQuality, {});
            if (out.status == .timeout) return error.Timeout;
            if (out.status != .ok) return error.AtError;
            const sig = out.value orelse return error.NoSignal;
            self.last_signal = sig;
            return sig;
        }

        /// Returns the last cached signal info without sending a command.
        pub fn getLastSignal(self: *const Self) ?types.CellularSignalInfo {
            return self.last_signal;
        }

        /// Returns a pointer to the stored SimInfo.
        pub fn getSimInfo(self: *Self) *types.SimInfo {
            return &self.sim_info;
        }

        /// Returns a pointer to the stored ModemInfo.
        pub fn getModemInfo(self: *Self) *types.ModemInfo {
            return &self.modem_info;
        }
    };
}
