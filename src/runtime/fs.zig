//! Runtime FS Contract

const std = @import("std");

pub const OpenMode = enum {
    read,
    write,
    read_write,
};

pub const Error = error{
    NotFound,
    PermissionDenied,
    IoError,
    NoSpace,
    InvalidPath,
};

/// Runtime file handle.
pub const File = struct {
    data: ?[]const u8 = null,
    ctx: *anyopaque,
    readFn: ?*const fn (ctx: *anyopaque, buf: []u8) Error!usize = null,
    writeFn: ?*const fn (ctx: *anyopaque, buf: []const u8) Error!usize = null,
    closeFn: *const fn (ctx: *anyopaque) void,
    size: u32,

    pub fn read(self: *File, buf: []u8) Error!usize {
        const f = self.readFn orelse return Error.PermissionDenied;
        return f(self.ctx, buf);
    }

    pub fn write(self: *File, buf: []const u8) Error!usize {
        const f = self.writeFn orelse return Error.PermissionDenied;
        return f(self.ctx, buf);
    }

    pub fn close(self: *File) void {
        self.closeFn(self.ctx);
    }

    pub fn readAll(self: *File, buf: []u8) Error![]const u8 {
        var total: usize = 0;
        while (total < buf.len) {
            const n = try self.read(buf[total..]);
            if (n == 0) break;
            total += n;
        }
        return buf[0..total];
    }
};

/// FS contract:
/// - `open(self: *Impl, path: []const u8, mode: OpenMode) -> ?File`
pub fn from(comptime Impl: type) type {
    comptime {
        const BaseType = switch (@typeInfo(Impl)) {
            .pointer => |p| p.child,
            else => Impl,
        };

        _ = @as(*const fn (*BaseType, []const u8, OpenMode) ?File, &BaseType.open);
    }
    return Impl;
}

test "File readAll with mock reader" {
    const Ctx = struct {
        data: []const u8,
        pos: usize,
    };

    var ctx = Ctx{ .data = "hello", .pos = 0 };

    const readFn = struct {
        fn read(ctx_ptr: *anyopaque, buf: []u8) Error!usize {
            const c: *Ctx = @ptrCast(@alignCast(ctx_ptr));
            const rem = c.data.len - c.pos;
            const n = @min(rem, buf.len);
            if (n == 0) return 0;
            @memcpy(buf[0..n], c.data[c.pos..][0..n]);
            c.pos += n;
            return n;
        }
        fn close(_: *anyopaque) void {}
    };

    var file = File{
        .ctx = @ptrCast(&ctx),
        .readFn = &readFn.read,
        .closeFn = &readFn.close,
        .size = 5,
    };

    var buf: [16]u8 = undefined;
    const out = try file.readAll(&buf);
    try std.testing.expectEqualStrings("hello", out);
}

test "File readAll propagates read errors" {
    const Ctx = struct {
        called: bool,
    };

    var ctx = Ctx{ .called = false };

    const readFn = struct {
        fn read(ctx_ptr: *anyopaque, _: []u8) Error!usize {
            const c: *Ctx = @ptrCast(@alignCast(ctx_ptr));
            c.called = true;
            return Error.IoError;
        }
        fn close(_: *anyopaque) void {}
    };

    var file = File{
        .ctx = @ptrCast(&ctx),
        .readFn = &readFn.read,
        .closeFn = &readFn.close,
        .size = 0,
    };

    var buf: [8]u8 = undefined;
    try std.testing.expectError(Error.IoError, file.readAll(&buf));
    try std.testing.expect(ctx.called);
}
