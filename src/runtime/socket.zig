//! Runtime Socket Contract

/// IPv4 address (a.b.c.d)
pub const Ipv4Address = [4]u8;

/// Fixed socket error set for contract signatures.
pub const Error = error{
    CreateFailed,
    BindFailed,
    ConnectFailed,
    SendFailed,
    RecvFailed,
    SetOptionFailed,
    Timeout,
    InvalidAddress,
    Closed,
    ListenFailed,
    AcceptFailed,
};

/// UDP receive result with source endpoint.
pub const RecvFromResult = struct {
    len: usize,
    src_addr: Ipv4Address,
    src_port: u16,
};

const Seal = struct {};

/// Construct a sealed Socket wrapper from a backend Impl type.
pub fn Make(comptime Impl: type) type {
    comptime {
        // Factory methods
        _ = @as(*const fn () Error!Impl, &Impl.tcp);
        _ = @as(*const fn () Error!Impl, &Impl.udp);

        // Basic operations
        _ = @as(*const fn (*Impl) void, &Impl.close);
        _ = @as(*const fn (*Impl, Ipv4Address, u16) Error!void, &Impl.connect);
        _ = @as(*const fn (*Impl, []const u8) Error!usize, &Impl.send);
        _ = @as(*const fn (*Impl, []u8) Error!usize, &Impl.recv);

        // Socket options
        _ = @as(*const fn (*Impl, u32) void, &Impl.setRecvTimeout);
        _ = @as(*const fn (*Impl, u32) void, &Impl.setSendTimeout);
        _ = @as(*const fn (*Impl, bool) void, &Impl.setTcpNoDelay);

        // UDP operations
        _ = @as(*const fn (*Impl, Ipv4Address, u16, []const u8) Error!usize, &Impl.sendTo);
        _ = @as(*const fn (*Impl, []u8) Error!RecvFromResult, &Impl.recvFrom);

        // Server operations
        _ = @as(*const fn (*Impl, Ipv4Address, u16) Error!void, &Impl.bind);
        _ = @as(*const fn (*Impl) Error!u16, &Impl.getBoundPort);
        _ = @as(*const fn (*Impl) Error!void, &Impl.listen);
        _ = @as(*const fn (*Impl) Error!Impl, &Impl.accept);

        // Async I/O support
        _ = @as(*const fn (*Impl) i32, &Impl.getFd);
        _ = @as(*const fn (*Impl, bool) Error!void, &Impl.setNonBlocking);
    }

    const SocketType = struct {
        impl: Impl,
        pub const seal: Seal = .{};
        pub const BackendType = Impl;

        // Factory methods
        pub fn tcp() Error!@This() {
            return .{ .impl = try Impl.tcp() };
        }

        pub fn udp() Error!@This() {
            return .{ .impl = try Impl.udp() };
        }

        // Basic operations
        pub fn close(self: *@This()) void {
            self.impl.close();
        }

        pub fn connect(self: *@This(), addr: Ipv4Address, port: u16) Error!void {
            return self.impl.connect(addr, port);
        }

        pub fn send(self: *@This(), data: []const u8) Error!usize {
            return self.impl.send(data);
        }

        pub fn recv(self: *@This(), buf: []u8) Error!usize {
            return self.impl.recv(buf);
        }

        // Socket options
        pub fn setRecvTimeout(self: *@This(), timeout_ms: u32) void {
            self.impl.setRecvTimeout(timeout_ms);
        }

        pub fn setSendTimeout(self: *@This(), timeout_ms: u32) void {
            self.impl.setSendTimeout(timeout_ms);
        }

        pub fn setTcpNoDelay(self: *@This(), enabled: bool) void {
            self.impl.setTcpNoDelay(enabled);
        }

        // UDP operations
        pub fn sendTo(self: *@This(), addr: Ipv4Address, port: u16, data: []const u8) Error!usize {
            return self.impl.sendTo(addr, port, data);
        }

        pub fn recvFrom(self: *@This(), buf: []u8) Error!RecvFromResult {
            return self.impl.recvFrom(buf);
        }

        // Server operations
        pub fn bind(self: *@This(), addr: Ipv4Address, port: u16) Error!void {
            return self.impl.bind(addr, port);
        }

        pub fn getBoundPort(self: *@This()) Error!u16 {
            return self.impl.getBoundPort();
        }

        pub fn listen(self: *@This()) Error!void {
            return self.impl.listen();
        }

        pub fn accept(self: *@This()) Error!@This() {
            return .{ .impl = try self.impl.accept() };
        }

        // Async I/O support
        pub fn getFd(self: *@This()) i32 {
            return self.impl.getFd();
        }

        pub fn setNonBlocking(self: *@This(), enabled: bool) Error!void {
            return self.impl.setNonBlocking(enabled);
        }
    };
    return is(SocketType);
}

/// Validate that Impl satisfies the sealed Socket contract.
pub fn is(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "seal") or @TypeOf(Impl.seal) != Seal) {
            @compileError("Impl must have pub const seal: socket.Seal — use socket.Make(Backend) to construct");
        }
    }
    return Impl;
}

/// Parse IPv4 address from text (e.g. "192.168.1.10").
pub fn parseIpv4(str: []const u8) ?Ipv4Address {
    var addr: Ipv4Address = undefined;
    var idx: usize = 0;
    var num: u16 = 0;
    var dots: u8 = 0;
    var has_digit_in_segment = false;

    if (str.len == 0) return null;

    for (str) |ch| {
        if (ch >= '0' and ch <= '9') {
            num = num * 10 + (ch - '0');
            if (num > 255) return null;
            has_digit_in_segment = true;
        } else if (ch == '.') {
            if (!has_digit_in_segment) return null;
            if (idx >= 3) return null;
            addr[idx] = @intCast(num);
            idx += 1;
            num = 0;
            dots += 1;
            has_digit_in_segment = false;
        } else {
            return null;
        }
    }

    if (dots != 3 or idx != 3 or !has_digit_in_segment) return null;
    addr[3] = @intCast(num);
    return addr;
}
