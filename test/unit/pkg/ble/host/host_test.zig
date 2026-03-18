const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const host_mod = embed.pkg.ble.host.host_mod;
const runtime = embed.runtime;
const hci_mod = embed.pkg.ble.host.hci.hci;
const acl_mod = embed.pkg.ble.host.hci.acl;
const hci = embed.pkg.ble.host.hci;
const events_mod = embed.pkg.ble.host.hci.events;
const l2cap_mod = embed.pkg.ble.host.l2cap.l2cap;
const att_mod = embed.pkg.ble.host.att.att;
const gap_mod = embed.pkg.ble.host.gap.gap;
const gatt_server = embed.pkg.ble.gatt.server;
const gatt_client = embed.pkg.ble.gatt.client;

fn MockHci() type {
    return struct {
        const Self = @This();
        const HciError = error{ WouldBlock, HciError };

        const PollFlags = packed struct {
            readable: bool = false,
            writable: bool = false,
            _padding: u6 = 0,
        };

        written_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        rx_queue: [16][64]u8 = undefined,
        rx_lens: [16]usize = [_]usize{0} ** 16,
        rx_head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        rx_tail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        pub fn read(self: *Self, buf: []u8) HciError!usize {
            const head = self.rx_head.load(.acquire);
            const tail = self.rx_tail.load(.acquire);
            if (head == tail) return error.WouldBlock;

            const idx = tail % 16;
            const n = @min(buf.len, self.rx_lens[idx]);
            @memcpy(buf[0..n], self.rx_queue[idx][0..n]);
            self.rx_tail.store(tail + 1, .release);
            return n;
        }

        pub fn write(self: *Self, buf: []const u8) HciError!usize {
            _ = self.written_count.fetchAdd(1, .acq_rel);
            return buf.len;
        }

        pub fn poll(self: *Self, flags: PollFlags, _: i32) PollFlags {
            return .{
                .readable = flags.readable and (self.rx_head.load(.acquire) != self.rx_tail.load(.acquire)),
                .writable = flags.writable,
            };
        }

        pub fn injectPacket(self: *Self, data: []const u8) void {
            const head = self.rx_head.load(.acquire);
            const idx = head % 16;
            @memcpy(self.rx_queue[idx][0..data.len], data);
            self.rx_lens[idx] = data.len;
            self.rx_head.store(head + 1, .release);
        }

        pub fn injectInitSequence(self: *Self) void {
            self.injectPacket(&[_]u8{
                @intFromEnum(hci_mod.PacketType.event),
                0x0E,
                0x04,
                0x01,
                0x03,
                0x0C,
                0x00,
            });
            self.injectPacket(&[_]u8{
                @intFromEnum(hci_mod.PacketType.event),
                0x0E,
                0x07,
                0x01,
                0x02,
                0x20,
                0x00,
                0xFB,
                0x00,
                12,
            });
            self.injectPacket(&[_]u8{
                @intFromEnum(hci_mod.PacketType.event),
                0x0E,
                0x0A,
                0x01,
                0x09,
                0x10,
                0x00,
                0x52,
                0x5C,
                0x11,
                0xE0,
                0x88,
                0x98,
            });
            self.injectPacket(&[_]u8{
                @intFromEnum(hci_mod.PacketType.event),
                0x0E,
                0x04,
                0x01,
                0x01,
                0x0C,
                0x00,
            });
            self.injectPacket(&[_]u8{
                @intFromEnum(hci_mod.PacketType.event),
                0x0E,
                0x04,
                0x01,
                0x01,
                0x20,
                0x00,
            });
        }
    };
}

test "Host start reads buffer size and initializes credits" {
    const Rt = runtime.std;
    const Mock = MockHci();

    var hci_driver = Mock{};
    hci_driver.injectInitSequence();

    const TestHost = host_mod.Host(Rt, Mock, &.{});
    var host = TestHost.init(&hci_driver, std.testing.allocator);
    defer host.deinit();

    try host.start(.{});
    std.Thread.sleep(10 * std.time.ns_per_ms);

    try std.testing.expectEqual(@as(u16, 251), host.acl_max_len);
    try std.testing.expectEqual(@as(u16, 12), host.acl_max_slots);
    try std.testing.expectEqual(@as(u32, 12), host.getAclCredits());
    try std.testing.expectEqual(@as(u8, 0x52), host.bd_addr[0]);
    try std.testing.expectEqual(@as(u8, 0x11), host.bd_addr[2]);
    try std.testing.expect(hci_driver.written_count.load(.acquire) >= 5);

    host.stop();
}

test "Host writeLoop respects ACL credits" {
    const Rt = runtime.std;
    const Mock = MockHci();

    var hci_driver = Mock{};
    hci_driver.injectInitSequence();

    const TestHost = host_mod.Host(Rt, Mock, &.{});
    var host = TestHost.init(&hci_driver, std.testing.allocator);
    defer host.deinit();

    try host.start(.{});
    std.Thread.sleep(10 * std.time.ns_per_ms);

    const written_before = hci_driver.written_count.load(.acquire);

    try host.sendData(0x0040, l2cap_mod.CID_ATT, "test data");

    std.Thread.sleep(50 * std.time.ns_per_ms);

    const written_after = hci_driver.written_count.load(.acquire);
    try std.testing.expect(written_after > written_before);
    try std.testing.expect(host.getAclCredits() < 12);

    host.stop();
}

test "Host NCP event releases credits" {
    const Rt = runtime.std;
    const Mock = MockHci();

    var hci_driver = Mock{};
    hci_driver.injectInitSequence();

    const TestHost = host_mod.Host(Rt, Mock, &.{});
    var host = TestHost.init(&hci_driver, std.testing.allocator);
    defer host.deinit();

    try host.start(.{});
    std.Thread.sleep(10 * std.time.ns_per_ms);

    try host.sendData(0x0040, l2cap_mod.CID_ATT, "test");
    std.Thread.sleep(50 * std.time.ns_per_ms);
    const credits_after_send = host.getAclCredits();

    hci_driver.injectPacket(&[_]u8{
        @intFromEnum(hci_mod.PacketType.event),
        0x13,
        0x05,
        0x01,
        0x40,
        0x00,
        0x05,
        0x00,
    });

    std.Thread.sleep(200 * std.time.ns_per_ms);

    const credits_after_ncp = host.getAclCredits();
    try std.testing.expect(credits_after_ncp > credits_after_send);

    host.stop();
}
