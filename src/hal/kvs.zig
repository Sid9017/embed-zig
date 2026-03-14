//! Key-value store HAL wrapper.

const hal_marker = @import("marker.zig");

pub const KvsError = error{
    NotFound,
    BufferTooSmall,
    InvalidKey,
    StorageFull,
    WriteError,
    ReadError,
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .kvs;
}

/// spec must define Driver with getU32/setU32/getString/setString/commit and meta.id.
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };

    comptime {
        _ = @as(*const fn (*BaseDriver, []const u8) KvsError!u32, &BaseDriver.getU32);
        _ = @as(*const fn (*BaseDriver, []const u8, u32) KvsError!void, &BaseDriver.setU32);
        _ = @as(*const fn (*BaseDriver, []const u8, []u8) KvsError![]const u8, &BaseDriver.getString);
        _ = @as(*const fn (*BaseDriver, []const u8, []const u8) KvsError!void, &BaseDriver.setString);
        _ = @as(*const fn (*BaseDriver) KvsError!void, &BaseDriver.commit);
        _ = @as(*const fn (*BaseDriver, []const u8) KvsError!i32, &BaseDriver.getI32);
        _ = @as(*const fn (*BaseDriver, []const u8, i32) KvsError!void, &BaseDriver.setI32);
        _ = @as(*const fn (*BaseDriver, []const u8) KvsError!void, &BaseDriver.erase);
        _ = @as(*const fn (*BaseDriver) KvsError!void, &BaseDriver.eraseAll);

        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .kvs,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn getU32(self: *Self, key: []const u8) !u32 {
            return self.driver.getU32(key);
        }

        pub fn setU32(self: *Self, key: []const u8, value: u32) !void {
            return self.driver.setU32(key, value);
        }

        pub fn getU32OrDefault(self: *Self, key: []const u8, default: u32) u32 {
            return self.getU32(key) catch default;
        }

        pub fn getI32(self: *Self, key: []const u8) !i32 {
            return self.driver.getI32(key);
        }

        pub fn setI32(self: *Self, key: []const u8, value: i32) !void {
            return self.driver.setI32(key, value);
        }

        pub fn getString(self: *Self, key: []const u8, buf: []u8) ![]const u8 {
            return self.driver.getString(key, buf);
        }

        pub fn setString(self: *Self, key: []const u8, value: []const u8) !void {
            return self.driver.setString(key, value);
        }

        pub fn getBool(self: *Self, key: []const u8) !bool {
            return (try self.getU32(key)) != 0;
        }

        pub fn setBool(self: *Self, key: []const u8, value: bool) !void {
            return self.setU32(key, if (value) 1 else 0);
        }

        pub fn commit(self: *Self) !void {
            return self.driver.commit();
        }

        pub fn erase(self: *Self, key: []const u8) !void {
            return self.driver.erase(key);
        }

        pub fn eraseAll(self: *Self) !void {
            return self.driver.eraseAll();
        }

        pub fn increment(self: *Self, key: []const u8) !u32 {
            const cur = self.getU32OrDefault(key, 0);
            const next = cur +| 1;
            try self.setU32(key, next);
            return next;
        }

        pub fn decrement(self: *Self, key: []const u8) !u32 {
            const cur = self.getU32OrDefault(key, 0);
            const next = cur -| 1;
            try self.setU32(key, next);
            return next;
        }
    };
}
