const std = @import("std");
const runtime = @import("../runtime.zig");

pub const StdFs = struct {
    const FileCtx = struct {
        file: std.fs.File,
    };

    pub fn open(_: *@This(), path: []const u8, mode: runtime.fs.OpenMode) ?runtime.fs.File {
        const file = switch (mode) {
            .read => openFilePath(path, .{ .mode = .read_only }) catch return null,
            .write => createFilePath(path, .{ .read = false, .truncate = true }) catch return null,
            .read_write => openFilePath(path, .{ .mode = .read_write }) catch createFilePath(path, .{ .read = true, .truncate = false }) catch return null,
        };

        const ctx = std.heap.page_allocator.create(FileCtx) catch {
            file.close();
            return null;
        };
        ctx.* = .{ .file = file };

        return runtime.fs.File{
            .ctx = @ptrCast(ctx),
            .readFn = switch (mode) {
                .write => null,
                else => &readFn,
            },
            .writeFn = switch (mode) {
                .read => null,
                else => &writeFn,
            },
            .closeFn = &closeFn,
            .size = fileSize(&ctx.file),
        };
    }

    fn fileSize(file: *std.fs.File) u32 {
        const st = file.stat() catch return 0;
        return if (st.size > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(st.size);
    }

    fn readFn(ctx_ptr: *anyopaque, buf: []u8) runtime.fs.Error!usize {
        const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
        return ctx.file.read(buf) catch |err| switch (err) {
            error.AccessDenied => runtime.fs.Error.PermissionDenied,
            else => runtime.fs.Error.IoError,
        };
    }

    fn writeFn(ctx_ptr: *anyopaque, buf: []const u8) runtime.fs.Error!usize {
        const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
        return ctx.file.write(buf) catch |err| switch (err) {
            error.AccessDenied => runtime.fs.Error.PermissionDenied,
            error.NoSpaceLeft => runtime.fs.Error.NoSpace,
            else => runtime.fs.Error.IoError,
        };
    }

    fn closeFn(ctx_ptr: *anyopaque) void {
        const ctx: *FileCtx = @ptrCast(@alignCast(ctx_ptr));
        ctx.file.close();
        std.heap.page_allocator.destroy(ctx);
    }

    fn openFilePath(path: []const u8, flags: std.fs.File.OpenFlags) !std.fs.File {
        if (std.fs.path.isAbsolute(path)) {
            return std.fs.openFileAbsolute(path, flags);
        }
        return std.fs.cwd().openFile(path, flags);
    }

    fn createFilePath(path: []const u8, flags: std.fs.File.CreateFlags) !std.fs.File {
        if (std.fs.path.isAbsolute(path)) {
            return std.fs.createFileAbsolute(path, flags);
        }
        return std.fs.cwd().createFile(path, flags);
    }
};
