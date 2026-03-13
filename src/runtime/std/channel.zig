//! 基于双 pipe 的 MPMC channel，支持 buffered 和 unbuffered 两种模式。
//!
//! Buffered (capacity > 0):
//!
//!   read_pipe  —— 数据就绪信号。token 数 = ring buffer 中的 event 数。
//!                  send 写入数据后往 read_pipe 写 1 token；
//!                  recv 从 read_pipe 读 1 token，没有则阻塞。
//!
//!   write_pipe —— 空位就绪信号。token 数 = ring buffer 中的剩余空位数。
//!                  init 时预填 capacity 个 token；
//!                  send 从 write_pipe 读 1 token，满则阻塞；
//!                  recv 取出数据后往 write_pipe 写 1 token 归还空位。
//!
//!   不变量：read_pipe token 数 + write_pipe token 数 = capacity。
//!
//! Unbuffered (capacity == 0):
//!
//!   Rendezvous 语义，与 Go 的 make(chan T) 一致。
//!   send 阻塞直到有 receiver 取走数据；recv 阻塞直到有 sender 提供数据。
//!
//!   read_pipe  —— sender 写 token 通知 receiver "数据已放入 slot"
//!   write_pipe —— receiver 写 token 通知 sender "数据已取走，你可以返回了"

const std = @import("std");

pub fn Channel(comptime Event: type) type {
    return struct {
        inner: *Inner,

        pub const event_t = Event;
        pub const RecvResult = struct { value: Event, ok: bool };
        pub const SendResult = struct { ok: bool };

        const Inner = struct {
            allocator: std.mem.Allocator,
            mutex: std.Thread.Mutex,
            ring: []Event,
            head: usize,
            tail: usize,
            len: usize,
            capacity: usize,
            read_pipe_r: std.posix.fd_t,
            read_pipe_w: std.posix.fd_t,
            write_pipe_r: std.posix.fd_t,
            write_pipe_w: std.posix.fd_t,
            closed: bool,
            slot: Event,
            send_mutex: std.Thread.Mutex,
        };

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const ring: []Event = if (capacity > 0)
                try allocator.alloc(Event, capacity)
            else
                @constCast(&[_]Event{});
            errdefer if (capacity > 0) allocator.free(ring);

            const read_pipe = try std.posix.pipe();
            errdefer {
                std.posix.close(read_pipe[0]);
                std.posix.close(read_pipe[1]);
            }

            const write_pipe = try std.posix.pipe();
            errdefer {
                std.posix.close(write_pipe[0]);
                std.posix.close(write_pipe[1]);
            }

            const inner = try allocator.create(Inner);
            inner.* = .{
                .allocator = allocator,
                .mutex = .{},
                .ring = ring,
                .head = 0,
                .tail = 0,
                .len = 0,
                .capacity = capacity,
                .read_pipe_r = read_pipe[0],
                .read_pipe_w = read_pipe[1],
                .write_pipe_r = write_pipe[0],
                .write_pipe_w = write_pipe[1],
                .closed = false,
                .slot = undefined,
                .send_mutex = .{},
            };

            for (0..capacity) |_| {
                writeToken(inner.write_pipe_w);
            }

            return .{ .inner = inner };
        }

        pub fn deinit(self: *Self) void {
            const inner = self.inner;
            std.posix.close(inner.read_pipe_r);
            std.posix.close(inner.read_pipe_w);
            std.posix.close(inner.write_pipe_r);
            std.posix.close(inner.write_pipe_w);
            if (inner.capacity > 0) inner.allocator.free(inner.ring);
            inner.allocator.destroy(inner);
        }

        pub fn close(self: *Self) void {
            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();
            self.inner.closed = true;
            writeToken(self.inner.read_pipe_w);
            writeToken(self.inner.write_pipe_w);
        }

        pub fn send(self: *Self, value: Event) !SendResult {
            if (self.inner.capacity == 0)
                return self.sendUnbuffered(value);
            return self.sendBuffered(value);
        }

        pub fn recv(self: *Self) !RecvResult {
            if (self.inner.capacity == 0)
                return self.recvUnbuffered();
            return self.recvBuffered();
        }

        fn sendBuffered(self: *Self, value: Event) !SendResult {
            waitFd(self.inner.write_pipe_r);
            readToken(self.inner.write_pipe_r);

            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            if (self.inner.closed) {
                writeToken(self.inner.write_pipe_w);
                return .{ .ok = false };
            }

            self.inner.ring[self.inner.tail] = value;
            self.inner.tail = (self.inner.tail + 1) % self.inner.capacity;
            self.inner.len += 1;
            writeToken(self.inner.read_pipe_w);
            return .{ .ok = true };
        }

        fn recvBuffered(self: *Self) !RecvResult {
            waitFd(self.inner.read_pipe_r);
            readToken(self.inner.read_pipe_r);

            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            if (self.inner.len == 0) {
                if (self.inner.closed) {
                    writeToken(self.inner.read_pipe_w);
                    return .{ .value = undefined, .ok = false };
                }
                writeToken(self.inner.read_pipe_w);
                return .{ .value = undefined, .ok = false };
            }

            const value = self.inner.ring[self.inner.head];
            self.inner.head = (self.inner.head + 1) % self.inner.capacity;
            self.inner.len -= 1;
            writeToken(self.inner.write_pipe_w);
            return .{ .value = value, .ok = true };
        }

        // Unbuffered rendezvous: only one sender at a time can use the slot.
        // send_mutex serializes senders so each gets a clean handshake cycle.
        fn sendUnbuffered(self: *Self, value: Event) !SendResult {
            self.inner.send_mutex.lock();
            defer self.inner.send_mutex.unlock();

            {
                self.inner.mutex.lock();
                defer self.inner.mutex.unlock();
                if (self.inner.closed) return .{ .ok = false };
                self.inner.slot = value;
            }

            writeToken(self.inner.read_pipe_w);

            waitFd(self.inner.write_pipe_r);
            readToken(self.inner.write_pipe_r);

            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();
            if (self.inner.closed) {
                writeToken(self.inner.write_pipe_w);
                return .{ .ok = false };
            }
            return .{ .ok = true };
        }

        fn recvUnbuffered(self: *Self) !RecvResult {
            waitFd(self.inner.read_pipe_r);
            readToken(self.inner.read_pipe_r);

            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            if (self.inner.closed) {
                writeToken(self.inner.read_pipe_w);
                return .{ .value = undefined, .ok = false };
            }

            const value = self.inner.slot;
            writeToken(self.inner.write_pipe_w);
            return .{ .value = value, .ok = true };
        }

        pub fn trySend(self: *Self, value: Event) SendResult {
            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            if (self.inner.closed) return .{ .ok = false };
            if (self.inner.capacity == 0) return .{ .ok = false };
            if (self.inner.len >= self.inner.capacity) return .{ .ok = false };

            readToken(self.inner.write_pipe_r);
            self.inner.ring[self.inner.tail] = value;
            self.inner.tail = (self.inner.tail + 1) % self.inner.capacity;
            self.inner.len += 1;
            writeToken(self.inner.read_pipe_w);
            return .{ .ok = true };
        }

        pub fn tryRecv(self: *Self) RecvResult {
            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            if (self.inner.capacity == 0) return .{ .value = undefined, .ok = false };
            if (self.inner.len == 0) {
                return .{ .value = undefined, .ok = false };
            }

            readToken(self.inner.read_pipe_r);
            const value = self.inner.ring[self.inner.head];
            self.inner.head = (self.inner.head + 1) % self.inner.capacity;
            self.inner.len -= 1;
            writeToken(self.inner.write_pipe_w);
            return .{ .value = value, .ok = true };
        }

        pub fn readFd(self: *const Self) std.posix.fd_t {
            return self.inner.read_pipe_r;
        }

        pub fn writeFd(self: *const Self) std.posix.fd_t {
            return self.inner.write_pipe_r;
        }

        pub fn isSelectable() void {}

        fn writeToken(fd: std.posix.fd_t) void {
            const token: [1]u8 = .{1};
            _ = std.posix.write(fd, &token) catch {};
        }

        fn readToken(fd: std.posix.fd_t) void {
            var buf: [1]u8 = undefined;
            _ = std.posix.read(fd, &buf) catch {};
        }

        fn waitFd(fd: std.posix.fd_t) void {
            var fds = [_]std.posix.pollfd{.{
                .fd = fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            _ = std.posix.poll(&fds, -1) catch {};
        }
    };
}
