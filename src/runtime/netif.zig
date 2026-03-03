//! Runtime Network Interface Contract

const std = @import("std");

pub const Ipv4Address = [4]u8;
pub const MacAddress = [6]u8;
pub const IfName = [16]u8;

pub const State = enum {
    down,
    up,
    connected,
};

pub const DhcpMode = enum {
    disabled,
    client,
    server,
};

pub const types = struct {
    pub const DnsServers = struct {
        primary: Ipv4Address,
        secondary: Ipv4Address,
    };
};

pub const Info = struct {
    name: IfName = std.mem.zeroes(IfName),
    name_len: u8 = 0,
    mac: MacAddress = std.mem.zeroes(MacAddress),
    state: State = .down,
    dhcp: DhcpMode = .disabled,
    ip: Ipv4Address = .{ 0, 0, 0, 0 },
    netmask: Ipv4Address = .{ 0, 0, 0, 0 },
    gateway: Ipv4Address = .{ 0, 0, 0, 0 },
    dns_main: Ipv4Address = .{ 0, 0, 0, 0 },
    dns_backup: Ipv4Address = .{ 0, 0, 0, 0 },

    pub fn getName(self: *const Info) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Route = struct {
    dest: Ipv4Address = .{ 0, 0, 0, 0 },
    mask: Ipv4Address = .{ 0, 0, 0, 0 },
    gateway: Ipv4Address = .{ 0, 0, 0, 0 },
    iface: IfName = std.mem.zeroes(IfName),
    iface_len: u8 = 0,
    metric: u16 = 0,
};

/// NetIf contract:
/// - `list() -> []const IfName`
/// - `get(name: IfName) -> ?Info`
/// - `getDefault() -> ?IfName`
/// - `setDefault(name: IfName) -> void`
/// - `up(name: IfName) -> void`
/// - `down(name: IfName) -> void`
/// - `getDns() -> types.DnsServers`
/// - `setDns(primary: Ipv4Address, secondary: ?Ipv4Address) -> void`
/// - `addRoute(route: Route) -> void`
/// - `delRoute(dest: Ipv4Address, mask: Ipv4Address) -> void`
pub fn from(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () []const IfName, &Impl.list);
        _ = @as(*const fn (IfName) ?Info, &Impl.get);
        _ = @as(*const fn () ?IfName, &Impl.getDefault);
        _ = @as(*const fn (IfName) void, &Impl.setDefault);
        _ = @as(*const fn (IfName) void, &Impl.up);
        _ = @as(*const fn (IfName) void, &Impl.down);
        _ = @as(*const fn () types.DnsServers, &Impl.getDns);
        _ = @as(*const fn (Ipv4Address, ?Ipv4Address) void, &Impl.setDns);
        _ = @as(*const fn (Route) void, &Impl.addRoute);
        _ = @as(*const fn (Ipv4Address, Ipv4Address) void, &Impl.delRoute);
    }
    return Impl;
}

pub fn ifName(name: []const u8) IfName {
    var out: IfName = std.mem.zeroes(IfName);
    const n = @min(name.len, out.len);
    @memcpy(out[0..n], name[0..n]);
    return out;
}

test "ifName helper" {
    const n = ifName("sta");
    try std.testing.expectEqual(@as(u8, 's'), n[0]);
    try std.testing.expectEqual(@as(u8, 't'), n[1]);
    try std.testing.expectEqual(@as(u8, 'a'), n[2]);
}
