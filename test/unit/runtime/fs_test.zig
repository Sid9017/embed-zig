const std = @import("std");
const testing = std.testing;

const embed = @import("embed");
const fs = embed.runtime.fs;

test "File readAll with mock reader" {
    const Ctx = struct {
        data: []const u8,
        pos: usize,
    };

    var ctx = Ctx{ .data = "hello", .pos = 0 };

    const readFn = struct {
        fn read(ctx_ptr: *anyopaque, buf: []u8) fs.Error!usize {
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

    var file = fs.File{
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
        fn read(ctx_ptr: *anyopaque, _: []u8) fs.Error!usize {
            const c: *Ctx = @ptrCast(@alignCast(ctx_ptr));
            c.called = true;
            return fs.Error.IoError;
        }
        fn close(_: *anyopaque) void {}
    };

    var file = fs.File{
        .ctx = @ptrCast(&ctx),
        .readFn = &readFn.read,
        .closeFn = &readFn.close,
        .size = 0,
    };

    var buf: [8]u8 = undefined;
    try std.testing.expectError(fs.Error.IoError, file.readAll(&buf));
    try std.testing.expect(ctx.called);
}
