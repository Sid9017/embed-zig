//! Modem hardware driver stub. See plan.md 5.7.
const types = @import("../types.zig");
const io = @import("../io/io.zig");
const engine = @import("../at/engine.zig");

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
