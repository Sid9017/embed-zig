const std = @import("std");
const runtime = @import("../runtime.zig");

pub const StdIO = struct {
    pub const ReadyCallback = runtime.io.ReadyCallback;

    const WatchEntry = struct {
        read: ?ReadyCallback = null,
        write: ?ReadyCallback = null,
    };

    allocator: std.mem.Allocator,
    watchers: std.AutoHashMap(std.posix.fd_t, WatchEntry),
    wake_r: std.posix.fd_t,
    wake_w: std.posix.fd_t,

    pub fn init(allocator: std.mem.Allocator) anyerror!@This() {
        const pipe_fds = try std.posix.pipe();
        errdefer {
            std.posix.close(pipe_fds[0]);
            std.posix.close(pipe_fds[1]);
        }

        try setNonBlocking(pipe_fds[0]);
        try setNonBlocking(pipe_fds[1]);

        return .{
            .allocator = allocator,
            .watchers = std.AutoHashMap(std.posix.fd_t, WatchEntry).init(allocator),
            .wake_r = pipe_fds[0],
            .wake_w = pipe_fds[1],
        };
    }

    pub fn deinit(self: *@This()) void {
        self.watchers.deinit();
        std.posix.close(self.wake_r);
        std.posix.close(self.wake_w);
    }

    pub fn registerRead(self: *@This(), fd: std.posix.fd_t, cb: ReadyCallback) anyerror!void {
        var gop = try self.watchers.getOrPut(fd);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.read = cb;
    }

    pub fn registerWrite(self: *@This(), fd: std.posix.fd_t, cb: ReadyCallback) anyerror!void {
        var gop = try self.watchers.getOrPut(fd);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.write = cb;
    }

    pub fn unregister(self: *@This(), fd: std.posix.fd_t) void {
        _ = self.watchers.remove(fd);
    }

    pub fn poll(self: *@This(), timeout_ms: i32) usize {
        var fds = std.ArrayList(std.posix.pollfd).empty;
        defer fds.deinit(self.allocator);

        fds.append(self.allocator, .{ .fd = self.wake_r, .events = std.posix.POLL.IN, .revents = 0 }) catch return 0;

        var it = self.watchers.iterator();
        while (it.next()) |entry| {
            var events: i16 = 0;
            if (entry.value_ptr.read != null) events |= std.posix.POLL.IN;
            if (entry.value_ptr.write != null) events |= std.posix.POLL.OUT;
            if (events == 0) continue;
            fds.append(self.allocator, .{ .fd = entry.key_ptr.*, .events = events, .revents = 0 }) catch return 0;
        }

        const ready = std.posix.poll(fds.items, timeout_ms) catch return 0;
        if (ready == 0) return 0;

        var callbacks_called: usize = 0;

        if ((fds.items[0].revents & std.posix.POLL.IN) != 0) {
            self.drainWake();
        }

        var i: usize = 1;
        while (i < fds.items.len) : (i += 1) {
            const pfd = fds.items[i];
            const watch = self.watchers.get(pfd.fd) orelse continue;

            if ((pfd.revents & std.posix.POLL.IN) != 0) {
                if (watch.read) |cb| {
                    cb.callback(cb.ptr, pfd.fd);
                    callbacks_called += 1;
                }
            }
            if ((pfd.revents & std.posix.POLL.OUT) != 0) {
                if (watch.write) |cb| {
                    cb.callback(cb.ptr, pfd.fd);
                    callbacks_called += 1;
                }
            }
        }

        return callbacks_called;
    }

    pub fn wake(self: *@This()) void {
        const b: [1]u8 = .{1};
        _ = std.posix.write(self.wake_w, &b) catch |err| switch (err) {
            error.WouldBlock => {},
            else => {},
        };
    }

    fn drainWake(self: *@This()) void {
        var buf: [128]u8 = undefined;
        while (true) {
            const n = std.posix.read(self.wake_r, &buf) catch |err| switch (err) {
                error.WouldBlock => break,
                else => break,
            };
            if (n == 0) break;
        }
    }

    fn setNonBlocking(fd: std.posix.fd_t) !void {
        var fl_flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        const mask: usize = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
        fl_flags |= mask;
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, fl_flags);
    }
};
