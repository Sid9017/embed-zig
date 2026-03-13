const std = @import("std");

/// Channel transfers ownership of `T` between sender and receiver.
/// `T` must provide `deinit(*T) void`, and the final consumer is responsible
/// for calling it on the received value.
pub fn Channel(comptime T: type, comptime Impl: type) type {
    const ChannelType = struct {
        impl: Impl,

        pub const event_t = T;
        pub const RecvResult = struct { value: T, ok: bool };
        pub const SendResult = struct { ok: bool };

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !@This() {
            return .{
                .impl = try Impl.init(allocator, capacity),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.impl.deinit();
        }

        pub fn close(self: *@This()) void {
            self.impl.close();
        }

        pub fn send(self: *@This(), value: event_t) !SendResult {
            return try self.impl.send(value);
        }

        pub fn recv(self: *@This()) !RecvResult {
            return try self.impl.recv();
        }
    };
    return from(T, ChannelType);
}

pub fn from(comptime ExpectedEvent: type, comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "event_t")) {
            @compileError("Impl must define event_t");
        }
        if (Impl.event_t != ExpectedEvent) {
            @compileError("Channel.event_t does not match expected EventType");
        }
        const T = Impl.event_t;
        const RecvResult = struct { value: T, ok: bool };
        const SendResult = struct { ok: bool };

        _ = @as(*const fn () void, &Impl.isSelectable);
        _ = @as(*const fn (*Impl, T) anyerror!SendResult, &Impl.send);
        _ = @as(*const fn (*Impl) anyerror!RecvResult, &Impl.recv);
        _ = @as(*const fn (*Impl) void, &Impl.close);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (std.mem.Allocator, usize) anyerror!Impl, &Impl.init);
    }

    return Impl;
}
