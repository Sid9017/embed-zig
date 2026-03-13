const std = @import("std");
const select = @import("../select.zig");
const channel = @import("channel.zig");

pub fn Selector(comptime Event: type) type {
    const ChannelType = channel.Channel(Event);

    const Impl = struct {
        inner: *Inner,

        const Inner = struct {
            allocator: std.mem.Allocator,
            channels: []const ChannelType,
            pollfds: []std.posix.pollfd,
            prng: std.Random.DefaultPrng,
        };

        pub const channel_t = ChannelType;
        pub const event_t = Event;
        pub const RecvResult = struct { value: Event, index: usize, ok: bool };
        pub const SendResult = struct { index: usize, ok: bool };

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, channels: []const ChannelType) !Self {
            const n = channels.len;
            const pollfds = try allocator.alloc(std.posix.pollfd, n * 2);
            errdefer allocator.free(pollfds);

            for (channels, 0..) |ch, i| {
                pollfds[i] = .{
                    .fd = ch.readFd(),
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                };
                pollfds[n + i] = .{
                    .fd = ch.writeFd(),
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                };
            }

            const inner = try allocator.create(Inner);
            inner.* = .{
                .allocator = allocator,
                .channels = channels,
                .pollfds = pollfds,
                .prng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp())),
            };
            return .{ .inner = inner };
        }

        pub fn deinit(self: *Self) void {
            const inner = self.inner;
            inner.allocator.free(inner.pollfds);
            inner.allocator.destroy(inner);
        }

        pub fn recv(self: *Self, timeout_ms: i32) !RecvResult {
            const inner = self.inner;
            const n = inner.channels.len;
            if (n == 0) return .{ .value = undefined, .index = 0, .ok = false };

            const recv_fds = inner.pollfds[0..n];
            resetRevents(recv_fds);
            _ = std.posix.poll(recv_fds, timeout_ms) catch
                return .{ .value = undefined, .index = 0, .ok = false };
            return self.tryRecvRandom(recv_fds);
        }

        pub fn send(self: *Self, value: Event, timeout_ms: i32) !SendResult {
            const inner = self.inner;
            const n = inner.channels.len;
            if (n == 0) return .{ .index = 0, .ok = false };

            const send_fds = inner.pollfds[n .. n * 2];
            resetRevents(send_fds);
            _ = std.posix.poll(send_fds, timeout_ms) catch
                return .{ .index = 0, .ok = false };
            return self.trySendRandom(value, send_fds);
        }

        fn tryRecvRandom(self: *Self, recv_fds: []std.posix.pollfd) RecvResult {
            const inner = self.inner;
            const n = inner.channels.len;
            const start = inner.prng.random().uintLessThan(usize, n);
            var closed_idx: ?usize = null;
            for (0..n) |offset| {
                const idx = (start + offset) % n;
                if ((recv_fds[idx].revents & std.posix.POLL.IN) == 0) continue;

                var ch = inner.channels[idx];
                const r = ch.tryRecv();
                if (r.ok) return .{ .value = r.value, .index = idx, .ok = true };
                if (closed_idx == null) closed_idx = idx;
            }
            if (closed_idx) |idx| return .{ .value = undefined, .index = idx, .ok = false };
            return .{ .value = undefined, .index = 0, .ok = false };
        }

        fn trySendRandom(self: *Self, value: Event, send_fds: []std.posix.pollfd) SendResult {
            const inner = self.inner;
            const n = inner.channels.len;
            const start = inner.prng.random().uintLessThan(usize, n);
            for (0..n) |offset| {
                const idx = (start + offset) % n;
                if ((send_fds[idx].revents & std.posix.POLL.IN) == 0) continue;
                var ch = inner.channels[idx];
                if (ch.trySend(value).ok) return .{ .index = idx, .ok = true };
            }
            return .{ .index = 0, .ok = false };
        }

        fn resetRevents(pollfds: []std.posix.pollfd) void {
            for (pollfds) |*pfd| {
                pfd.revents = 0;
            }
        }
    };

    return select.Selector(Impl, ChannelType);
}
