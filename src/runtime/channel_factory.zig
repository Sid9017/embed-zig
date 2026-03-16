const std = @import("std");

const FactorySeal = struct {};

pub fn RecvResult(comptime T: type) type {
    return struct { value: T, ok: bool };
}

pub fn SendResult() type {
    return struct { ok: bool };
}

/// Bind a backend factory to produce sealed Channel types.
///
/// Usage:
///   const f = channel_factory.Make(std_channel_factory.ChannelFactory);
///   const EventCh = f.Channel(MyEvent);
///   var ch = try EventCh.init(allocator, 16);
pub fn Make(comptime impl: fn (type) type) type {
    return struct {
        pub const seal: FactorySeal = .{};

        pub fn Channel(comptime T: type) type {
            const Impl = impl(T);

            comptime {
                _ = @as(*const fn () void, &Impl.isSelectable);
                _ = @as(*const fn (*Impl, T) anyerror!SendResult(), &Impl.send);
                _ = @as(*const fn (*Impl) anyerror!RecvResult(T), &Impl.recv);
                _ = @as(*const fn (*Impl) void, &Impl.close);
                _ = @as(*const fn (*Impl) void, &Impl.deinit);
                _ = @as(*const fn (std.mem.Allocator, usize) anyerror!Impl, &Impl.init);
            }

            return struct {
                impl: Impl,

                pub const event_t = T;
                pub const BackendType = Impl;

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

                pub fn send(self: *@This(), value: event_t) !SendResult() {
                    return try self.impl.send(value);
                }

                pub fn recv(self: *@This()) !RecvResult(T) {
                    return try self.impl.recv();
                }
            };
        }
    };
}

/// Validate that T is a sealed Channel Factory (produced by channel_factory.ChannelFactory).
pub fn is(comptime T: type) type {
    comptime {
        if (!@hasDecl(T, "seal") or @TypeOf(T.seal) != FactorySeal) {
            @compileError("expected a ChannelFactory — use channel_factory.Make(backend) to construct");
        }
    }
    return T;
}
