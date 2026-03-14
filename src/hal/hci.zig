//! HCI Transport HAL Component.

const hal_marker = @import("marker.zig");

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .hci;
}

pub const PollFlags = packed struct {
    readable: bool = false,
    writable: bool = false,
    _padding: u6 = 0,
};

pub const PacketType = enum(u8) {
    command = 0x01,
    acl_data = 0x02,
    sync_data = 0x03,
    event = 0x04,
    iso_data = 0x05,
};

pub const Error = error{
    WouldBlock,
    HciError,
};

/// spec must define:
/// - Driver.read(*Driver, []u8) Error!usize
/// - Driver.write(*Driver, []const u8) Error!usize
/// - Driver.poll(*Driver, PollFlags, i32) PollFlags
/// - meta.id
pub fn from(comptime spec: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };

        _ = @as(*const fn (*BaseDriver, []u8) Error!usize, &BaseDriver.read);
        _ = @as(*const fn (*BaseDriver, []const u8) Error!usize, &BaseDriver.write);
        _ = @as(*const fn (*BaseDriver, PollFlags, i32) PollFlags, &BaseDriver.poll);
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .hci,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn read(self: *Self, buf: []u8) Error!usize {
            return self.driver.read(buf);
        }

        pub fn write(self: *Self, buf: []const u8) Error!usize {
            return self.driver.write(buf);
        }

        pub fn poll(self: *Self, flags: PollFlags, timeout_ms: i32) PollFlags {
            return self.driver.poll(flags, timeout_ms);
        }
    };
}
