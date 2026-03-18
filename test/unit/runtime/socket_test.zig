const std = @import("std");
const testing = std.testing;

const embed = @import("embed");
const socket = embed.runtime.socket;

test "parseIpv4" {
    const addr = socket.parseIpv4("192.168.1.1").?;
    try std.testing.expectEqual(@as(u8, 192), addr[0]);
    try std.testing.expectEqual(@as(u8, 168), addr[1]);
    try std.testing.expectEqual(@as(u8, 1), addr[2]);
    try std.testing.expectEqual(@as(u8, 1), addr[3]);

    try std.testing.expectEqual(@as(?socket.Ipv4Address, null), socket.parseIpv4("invalid"));
    try std.testing.expectEqual(@as(?socket.Ipv4Address, null), socket.parseIpv4("256.1.1.1"));
    try std.testing.expectEqual(@as(?socket.Ipv4Address, null), socket.parseIpv4("1.2.3."));
    try std.testing.expectEqual(@as(?socket.Ipv4Address, null), socket.parseIpv4(".1.2.3"));
    try std.testing.expectEqual(@as(?socket.Ipv4Address, null), socket.parseIpv4("1..2.3"));
}
