//! Modem hardware driver: owns Io/AtEngine, provides SIM/IMEI/signal queries.
//! See plan.md §5.7. No state machine — that lives in cellular.zig.

const types = @import("../types.zig");
const io = @import("../io/io.zig");
const engine = @import("../at/engine.zig");
const commands = @import("../at/commands.zig");

pub fn Modem(
    comptime Thread: type,
    comptime Notify: type,
    comptime Time: type,
    comptime Module: type,
    comptime Gpio: type,
    comptime at_buf_size: usize,
) type {
    comptime {
        _ = Thread;
        _ = Notify;
        _ = Module.commands;
        _ = Module.urcs;
        _ = Module.init_sequence;
    }
    const At = engine.AtEngine(Time, at_buf_size);
    return struct {
        const Self = @This();

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
        };

        at_engine: At = undefined,
        config: types.ModemConfig = .{},
        sim_info: types.SimInfo = .{},
        modem_info: types.ModemInfo = .{},
        last_signal: ?types.CellularSignalInfo = null,

        pub fn init(cfg: InitConfig) Self {
            var d: u8 = 0;
            const stub = io.Io{
                .ctx = @as(*anyopaque, @ptrCast(&d)),
                .readFn = _stubRead,
                .writeFn = _stubWrite,
                .pollFn = _stubPoll,
            };
            const at_io: io.Io = blk: {
                if (cfg.at_io) |x| break :blk x;
                if (cfg.io) |x| break :blk x;
                break :blk stub;
            };
            return .{
                .at_engine = At.init(at_io, cfg.time),
                .config = cfg.config,
            };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn at(self: *Self) *At {
            return &self.at_engine;
        }

        pub fn pppIo(self: *Self) ?io.Io {
            _ = self;
            return null;
        }

        pub fn enterCmux(self: *Self) !void {
            _ = self;
        }

        pub fn exitCmux(self: *Self) void {
            _ = self;
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

fn _stubRead(_: *anyopaque, _: []u8) io.IoError!usize {
    return error.WouldBlock;
}
fn _stubWrite(_: *anyopaque, buf: []const u8) io.IoError!usize {
    return buf.len;
}
fn _stubPoll(_: *anyopaque, _: i32) io.PollFlags {
    return .{};
}
