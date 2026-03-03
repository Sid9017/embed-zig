const std = @import("std");
const runtime = @import("../runtime.zig");

pub const StdNetIf = struct {
    const MaxRoutes = 16;

    const loop_if_names = [_]runtime.netif.IfName{
        runtime.netif.ifName("lo"),
        runtime.netif.ifName("lo0"),
    };

    const Shared = struct {
        mutex: std.Thread.Mutex = .{},
        state: runtime.netif.State = .connected,
        default_if: runtime.netif.IfName = runtime.netif.ifName("lo"),
        dns_main: runtime.netif.Ipv4Address = .{ 1, 1, 1, 1 },
        dns_backup: runtime.netif.Ipv4Address = .{ 8, 8, 8, 8 },
        routes: [MaxRoutes]runtime.netif.Route = undefined,
        route_count: usize = 0,
    };

    var shared = Shared{};

    pub fn list() []const runtime.netif.IfName {
        return loop_if_names[0..];
    }

    pub fn get(name: runtime.netif.IfName) ?runtime.netif.Info {
        if (!isLoopName(name)) return null;

        shared.mutex.lock();
        defer shared.mutex.unlock();

        var info = runtime.netif.Info{};
        info.name = name;
        info.name_len = ifNameLen(name);
        info.state = shared.state;
        info.dhcp = .disabled;
        info.ip = .{ 127, 0, 0, 1 };
        info.netmask = .{ 255, 0, 0, 0 };
        info.gateway = .{ 0, 0, 0, 0 };
        info.dns_main = shared.dns_main;
        info.dns_backup = shared.dns_backup;
        return info;
    }

    pub fn getDefault() ?runtime.netif.IfName {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        return shared.default_if;
    }

    pub fn setDefault(name: runtime.netif.IfName) void {
        if (!isLoopName(name)) return;
        shared.mutex.lock();
        defer shared.mutex.unlock();
        shared.default_if = name;
    }

    pub fn up(name: runtime.netif.IfName) void {
        if (!isLoopName(name)) return;
        shared.mutex.lock();
        defer shared.mutex.unlock();
        shared.state = .up;
    }

    pub fn down(name: runtime.netif.IfName) void {
        if (!isLoopName(name)) return;
        shared.mutex.lock();
        defer shared.mutex.unlock();
        shared.state = .down;
    }

    pub fn getDns() runtime.netif.types.DnsServers {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        return .{ .primary = shared.dns_main, .secondary = shared.dns_backup };
    }

    pub fn setDns(primary: runtime.netif.Ipv4Address, secondary: ?runtime.netif.Ipv4Address) void {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        shared.dns_main = primary;
        shared.dns_backup = secondary orelse .{ 0, 0, 0, 0 };
    }

    pub fn addRoute(route: runtime.netif.Route) void {
        shared.mutex.lock();
        defer shared.mutex.unlock();

        var i: usize = 0;
        while (i < shared.route_count) : (i += 1) {
            if (std.mem.eql(u8, &shared.routes[i].dest, &route.dest) and std.mem.eql(u8, &shared.routes[i].mask, &route.mask)) {
                shared.routes[i] = route;
                return;
            }
        }

        if (shared.route_count < shared.routes.len) {
            shared.routes[shared.route_count] = route;
            shared.route_count += 1;
        } else {
            shared.routes[shared.routes.len - 1] = route;
        }
    }

    pub fn delRoute(dest: runtime.netif.Ipv4Address, mask: runtime.netif.Ipv4Address) void {
        shared.mutex.lock();
        defer shared.mutex.unlock();

        var i: usize = 0;
        while (i < shared.route_count) : (i += 1) {
            if (std.mem.eql(u8, &shared.routes[i].dest, &dest) and std.mem.eql(u8, &shared.routes[i].mask, &mask)) {
                var j = i;
                while (j + 1 < shared.route_count) : (j += 1) {
                    shared.routes[j] = shared.routes[j + 1];
                }
                shared.route_count -= 1;
                return;
            }
        }
    }

    fn ifNameLen(name: runtime.netif.IfName) u8 {
        var i: usize = 0;
        while (i < name.len and name[i] != 0) : (i += 1) {}
        return @intCast(i);
    }

    fn isLoopName(name: runtime.netif.IfName) bool {
        for (loop_if_names) |n| {
            if (std.mem.eql(u8, &n, &name)) return true;
        }
        return false;
    }
};
