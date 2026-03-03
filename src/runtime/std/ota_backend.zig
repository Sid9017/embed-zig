const std = @import("std");
const runtime = @import("../runtime.zig");

pub const StdOtaBackend = struct {
    file: ?std.fs.File = null,
    expected_size: u32 = 0,
    written_size: u32 = 0,
    stage_path: []const u8 = ".runtime_ota_stage.bin",
    final_path: []const u8 = ".runtime_ota_applied.bin",

    pub fn init() runtime.ota_backend.Error!@This() {
        return .{};
    }

    pub fn begin(self: *@This(), image_size: u32) runtime.ota_backend.Error!void {
        self.abort();
        self.expected_size = image_size;
        self.written_size = 0;
        self.file = createFileAt(self.stage_path) catch return error.OpenFailed;
    }

    pub fn write(self: *@This(), chunk: []const u8) runtime.ota_backend.Error!void {
        var f = self.file orelse return error.WriteFailed;
        f.writeAll(chunk) catch return error.WriteFailed;
        self.file = f;

        const next = @as(u64, self.written_size) + chunk.len;
        self.written_size = if (next > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(next);
    }

    pub fn finalize(self: *@This()) runtime.ota_backend.Error!void {
        if (self.file) |f| {
            f.close();
            self.file = null;
        } else {
            return error.FinalizeFailed;
        }

        if (self.expected_size != 0 and self.written_size != self.expected_size) {
            return error.FinalizeFailed;
        }

        deleteFileAt(self.final_path);
        renameAt(self.stage_path, self.final_path) catch return error.FinalizeFailed;
    }

    pub fn abort(self: *@This()) void {
        if (self.file) |f| {
            f.close();
            self.file = null;
        }
        deleteFileAt(self.stage_path);
    }

    fn createFileAt(path: []const u8) !std.fs.File {
        if (std.fs.path.isAbsolute(path)) {
            return std.fs.createFileAbsolute(path, .{ .read = true, .truncate = true });
        }
        return std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
    }

    fn renameAt(old_path: []const u8, new_path: []const u8) !void {
        const old_abs = std.fs.path.isAbsolute(old_path);
        const new_abs = std.fs.path.isAbsolute(new_path);
        if (old_abs != new_abs) return error.InvalidPath;

        if (old_abs) {
            return std.fs.renameAbsolute(old_path, new_path);
        }
        return std.fs.cwd().rename(old_path, new_path);
    }

    fn deleteFileAt(path: []const u8) void {
        if (std.fs.path.isAbsolute(path)) {
            std.fs.deleteFileAbsolute(path) catch {};
            return;
        }
        std.fs.cwd().deleteFile(path) catch {};
    }
};
