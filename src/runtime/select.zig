//! Runtime selector contract.
//!
//! Both Channel and Impl are struct types.
//! Impl must store a pointer internally for heap state.
//!
//! timeout_ms: i32, 和 posix poll 语义一致：
//!   -1 = 永远等待
//!    0 = 立即返回（相当于 go select default）
//!   >0 = 等待指定毫秒数
//!
//! Required Impl surface (checked by `from`):
//! - `pub const channel_t`
//! - `pub const event_t`
//! - `pub const RecvResult`
//! - `pub const SendResult`
//! - `init(Allocator, []const channel_t) -> anyerror!Impl`
//! - `deinit(*Impl) -> void`
//! - `recv(*Impl, i32) -> anyerror!RecvResult`
//! - `send(*Impl, event_t, i32) -> anyerror!SendResult`

const std = @import("std");

pub fn Selector(comptime Impl: type, comptime Channel: type) type {
    comptime {
        if (!@hasDecl(Channel, "event_t")) {
            @compileError("Channel must define event_t");
        }
    }

    const Event = Channel.event_t;

    const SelectorType = struct {
        impl: Impl,

        pub const channel_t = Channel;
        pub const event_t = Event;
        pub const RecvResult = Impl.RecvResult;
        pub const SendResult = Impl.SendResult;

        pub fn init(allocator: std.mem.Allocator, channels: []const channel_t) !@This() {
            return .{ .impl = try Impl.init(allocator, channels) };
        }

        pub fn deinit(self: *@This()) void {
            self.impl.deinit();
        }

        pub fn recv(self: *@This(), timeout_ms: i32) !RecvResult {
            return try self.impl.recv(timeout_ms);
        }

        pub fn send(self: *@This(), value: event_t, timeout_ms: i32) !SendResult {
            return try self.impl.send(value, timeout_ms);
        }
    };
    return from(SelectorType);
}

pub fn from(comptime T: type) type {
    comptime {
        if (!@hasDecl(T, "channel_t")) {
            @compileError("Selector must define channel_t");
        }
        if (!@hasDecl(T, "event_t")) {
            @compileError("Selector must define event_t");
        }
        if (!@hasDecl(T, "RecvResult")) {
            @compileError("Selector must define RecvResult");
        }
        if (!@hasDecl(T, "SendResult")) {
            @compileError("Selector must define SendResult");
        }

        _ = @as(*const fn (std.mem.Allocator, []const T.channel_t) anyerror!T, &T.init);
        _ = @as(*const fn (*T) void, &T.deinit);
        _ = @as(*const fn (*T, i32) anyerror!T.RecvResult, &T.recv);
        _ = @as(*const fn (*T, T.event_t, i32) anyerror!T.SendResult, &T.send);
    }

    return T;
}
