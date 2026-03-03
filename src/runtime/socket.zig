//! Runtime Socket Contract

const std = @import("std");

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

/// Socket contract.
pub fn from(comptime Impl: type) type {
    comptime {
        const BaseType = switch (@typeInfo(Impl)) {
            .pointer => |p| p.child,
            else => Impl,
        };

        // Factory methods
        _ = @as(*const fn () Error!BaseType, &BaseType.tcp);
        _ = @as(*const fn () Error!BaseType, &BaseType.udp);

        // Basic operations
        _ = @as(*const fn (*BaseType) void, &BaseType.close);
        _ = @as(*const fn (*BaseType, Ipv4Address, u16) Error!void, &BaseType.connect);
        _ = @as(*const fn (*BaseType, []const u8) Error!usize, &BaseType.send);
        _ = @as(*const fn (*BaseType, []u8) Error!usize, &BaseType.recv);

        // Socket options
        _ = @as(*const fn (*BaseType, u32) void, &BaseType.setRecvTimeout);
        _ = @as(*const fn (*BaseType, u32) void, &BaseType.setSendTimeout);
        _ = @as(*const fn (*BaseType, bool) void, &BaseType.setTcpNoDelay);

        // UDP operations
        _ = @as(*const fn (*BaseType, Ipv4Address, u16, []const u8) Error!usize, &BaseType.sendTo);
        _ = @as(*const fn (*BaseType, []u8) Error!RecvFromResult, &BaseType.recvFrom);

        // Server operations
        _ = @as(*const fn (*BaseType, Ipv4Address, u16) Error!void, &BaseType.bind);
        _ = @as(*const fn (*BaseType) Error!u16, &BaseType.getBoundPort);
        _ = @as(*const fn (*BaseType) Error!void, &BaseType.listen);
        _ = @as(*const fn (*BaseType) Error!BaseType, &BaseType.accept);

        // Async I/O support
        _ = @as(*const fn (*BaseType) i32, &BaseType.getFd);
        _ = @as(*const fn (*BaseType, bool) Error!void, &BaseType.setNonBlocking);
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

test "parseIpv4" {
    const addr = parseIpv4("192.168.1.1").?;
    try std.testing.expectEqual(@as(u8, 192), addr[0]);
    try std.testing.expectEqual(@as(u8, 168), addr[1]);
    try std.testing.expectEqual(@as(u8, 1), addr[2]);
    try std.testing.expectEqual(@as(u8, 1), addr[3]);

    try std.testing.expectEqual(@as(?Ipv4Address, null), parseIpv4("invalid"));
    try std.testing.expectEqual(@as(?Ipv4Address, null), parseIpv4("256.1.1.1"));
    try std.testing.expectEqual(@as(?Ipv4Address, null), parseIpv4("1.2.3."));
    try std.testing.expectEqual(@as(?Ipv4Address, null), parseIpv4(".1.2.3"));
    try std.testing.expectEqual(@as(?Ipv4Address, null), parseIpv4("1..2.3"));
}
