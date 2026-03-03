const std = @import("std");
const runtime = @import("../runtime.zig");

pub const StdSocket = struct {
    fd: ?std.posix.fd_t = null,
    is_udp: bool = false,
    recv_timeout_ms: u32 = 0,
    send_timeout_ms: u32 = 0,

    pub fn tcp() runtime.socket.Error!@This() {
        const fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP) catch {
            return error.CreateFailed;
        };
        return .{ .fd = fd, .is_udp = false };
    }

    pub fn udp() runtime.socket.Error!@This() {
        const fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP) catch {
            return error.CreateFailed;
        };
        return .{ .fd = fd, .is_udp = true };
    }

    pub fn close(self: *@This()) void {
        if (self.fd) |fd| {
            std.posix.close(fd);
            self.fd = null;
        }
    }

    pub fn connect(self: *@This(), addr: runtime.socket.Ipv4Address, port: u16) runtime.socket.Error!void {
        const fd = try self.requireFd();
        var net_addr = std.net.Address.initIp4(addr, port);
        std.posix.connect(fd, &net_addr.any, net_addr.getOsSockLen()) catch |err| switch (err) {
            error.ConnectionTimedOut, error.WouldBlock => return error.Timeout,
            else => return error.ConnectFailed,
        };
    }

    pub fn send(self: *@This(), data: []const u8) runtime.socket.Error!usize {
        const fd = try self.requireFd();
        if (self.send_timeout_ms > 0 and !waitForFd(fd, std.posix.POLL.OUT, self.send_timeout_ms)) {
            return error.Timeout;
        }

        return std.posix.send(fd, data, 0) catch |err| switch (err) {
            error.WouldBlock => error.Timeout,
            else => error.SendFailed,
        };
    }

    pub fn recv(self: *@This(), buf: []u8) runtime.socket.Error!usize {
        const fd = try self.requireFd();
        if (self.recv_timeout_ms > 0 and !waitForFd(fd, std.posix.POLL.IN, self.recv_timeout_ms)) {
            return error.Timeout;
        }

        const n = std.posix.recv(fd, buf, 0) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionTimedOut => return error.Timeout,
            else => return error.RecvFailed,
        };
        if (n == 0 and !self.is_udp) return error.Closed;
        return n;
    }

    pub fn setRecvTimeout(self: *@This(), timeout_ms: u32) void {
        self.recv_timeout_ms = timeout_ms;
    }

    pub fn setSendTimeout(self: *@This(), timeout_ms: u32) void {
        self.send_timeout_ms = timeout_ms;
    }

    pub fn setTcpNoDelay(self: *@This(), enabled: bool) void {
        const fd = self.fd orelse return;
        const v: i32 = if (enabled) 1 else 0;
        std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&v)) catch {};
    }

    pub fn sendTo(self: *@This(), addr: runtime.socket.Ipv4Address, port: u16, data: []const u8) runtime.socket.Error!usize {
        const fd = try self.requireFd();
        var net_addr = std.net.Address.initIp4(addr, port);

        if (self.send_timeout_ms > 0 and !waitForFd(fd, std.posix.POLL.OUT, self.send_timeout_ms)) {
            return error.Timeout;
        }

        return std.posix.sendto(fd, data, 0, &net_addr.any, net_addr.getOsSockLen()) catch |err| switch (err) {
            error.WouldBlock => error.Timeout,
            else => error.SendFailed,
        };
    }

    pub fn recvFrom(self: *@This(), buf: []u8) runtime.socket.Error!runtime.socket.RecvFromResult {
        const fd = try self.requireFd();
        if (self.recv_timeout_ms > 0 and !waitForFd(fd, std.posix.POLL.IN, self.recv_timeout_ms)) {
            return error.Timeout;
        }

        var src: std.net.Address = undefined;
        var src_len: std.posix.socklen_t = @sizeOf(std.net.Address);

        const n = std.posix.recvfrom(fd, buf, 0, &src.any, &src_len) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionTimedOut => return error.Timeout,
            else => return error.RecvFailed,
        };

        if (src.any.family != std.posix.AF.INET) return error.InvalidAddress;
        const ip_ptr: *const [4]u8 = @ptrCast(&src.in.sa.addr);

        return .{
            .len = n,
            .src_addr = ip_ptr.*,
            .src_port = src.getPort(),
        };
    }

    pub fn bind(self: *@This(), addr: runtime.socket.Ipv4Address, port: u16) runtime.socket.Error!void {
        const fd = try self.requireFd();
        var net_addr = std.net.Address.initIp4(addr, port);
        std.posix.bind(fd, &net_addr.any, net_addr.getOsSockLen()) catch {
            return error.BindFailed;
        };
    }

    pub fn getBoundPort(self: *@This()) runtime.socket.Error!u16 {
        const fd = try self.requireFd();
        var local: std.net.Address = undefined;
        var local_len: std.posix.socklen_t = @sizeOf(std.net.Address);
        std.posix.getsockname(fd, &local.any, &local_len) catch {
            return error.BindFailed;
        };
        if (local.any.family != std.posix.AF.INET) return error.InvalidAddress;
        return local.getPort();
    }

    pub fn listen(self: *@This()) runtime.socket.Error!void {
        const fd = try self.requireFd();
        std.posix.listen(fd, 128) catch {
            return error.ListenFailed;
        };
    }

    pub fn accept(self: *@This()) runtime.socket.Error!@This() {
        const fd = try self.requireFd();
        var peer: std.net.Address = undefined;
        var peer_len: std.posix.socklen_t = @sizeOf(std.net.Address);
        const client_fd = std.posix.accept(fd, &peer.any, &peer_len, 0) catch {
            return error.AcceptFailed;
        };
        return .{ .fd = client_fd, .is_udp = false };
    }

    pub fn getFd(self: *@This()) i32 {
        return if (self.fd) |fd| @intCast(fd) else -1;
    }

    pub fn setNonBlocking(self: *@This(), enabled: bool) runtime.socket.Error!void {
        const fd = try self.requireFd();
        var fl_flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch return error.SetOptionFailed;
        const mask: usize = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
        if (enabled) {
            fl_flags |= mask;
        } else {
            fl_flags &= ~mask;
        }
        _ = std.posix.fcntl(fd, std.posix.F.SETFL, fl_flags) catch return error.SetOptionFailed;
    }

    fn requireFd(self: *@This()) runtime.socket.Error!std.posix.fd_t {
        return self.fd orelse error.Closed;
    }

    fn waitForFd(fd: std.posix.fd_t, events: i16, timeout_ms: u32) bool {
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const timeout_i32: i32 = if (timeout_ms > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(timeout_ms);
        const n = std.posix.poll(fds[0..], timeout_i32) catch return false;
        return n > 0 and (fds[0].revents & events) != 0;
    }
};
