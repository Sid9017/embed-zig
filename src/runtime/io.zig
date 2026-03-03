//! Runtime IO Contract (unified register/poll/wake model)

const std = @import("std");
const fd_t = std.posix.fd_t;

/// Shared callback type for I/O readiness notifications.
pub const ReadyCallback = struct {
    ptr: ?*anyopaque,
    callback: *const fn (?*anyopaque, fd_t) void,
};

/// IO contract:
/// - `ReadyCallback` struct with exact field types
/// - `init(Allocator) -> anyerror!Impl`
/// - `deinit(*Impl) -> void`
/// - `registerRead(*Impl, fd_t, ReadyCallback) -> anyerror!void`
/// - `registerWrite(*Impl, fd_t, ReadyCallback) -> anyerror!void`
/// - `unregister(*Impl, fd_t) -> void`
/// - `poll(*Impl, i32) -> usize`
/// - `wake(*Impl) -> void`
pub fn from(comptime Impl: type) type {
    comptime {
        const RC = Impl.ReadyCallback;

        if (@typeInfo(RC) != .@"struct") {
            @compileError("IO.ReadyCallback must be a struct");
        }
        if (!@hasField(RC, "ptr") or !@hasField(RC, "callback")) {
            @compileError("IO.ReadyCallback must contain 'ptr' and 'callback' fields");
        }

        const fields = @typeInfo(RC).@"struct".fields;
        var ptr_ok = false;
        var callback_ok = false;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "ptr")) {
                ptr_ok = (f.type == ?*anyopaque);
            } else if (std.mem.eql(u8, f.name, "callback")) {
                callback_ok = (f.type == *const fn (?*anyopaque, fd_t) void);
            }
        }

        if (!ptr_ok) @compileError("IO.ReadyCallback.ptr must be ?*anyopaque");
        if (!callback_ok) @compileError("IO.ReadyCallback.callback signature mismatch");

        _ = @as(*const fn (std.mem.Allocator) anyerror!Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl, fd_t, RC) anyerror!void, &Impl.registerRead);
        _ = @as(*const fn (*Impl, fd_t, RC) anyerror!void, &Impl.registerWrite);
        _ = @as(*const fn (*Impl, fd_t) void, &Impl.unregister);
        _ = @as(*const fn (*Impl, i32) usize, &Impl.poll);
        _ = @as(*const fn (*Impl) void, &Impl.wake);
    }
    return Impl;
}
