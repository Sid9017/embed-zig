const std = @import("std");
const testing = std.testing;
const embed = @import("embed");

const kvs_mod = embed.hal.kvs;

test "kvs wrapper" {
    const Mock = struct {
        value_u32: ?u32 = null,
        value_str: ?[]const u8 = null,
        commits: u32 = 0,

        pub fn getU32(self: *@This(), _: []const u8) kvs_mod.KvsError!u32 {
            return self.value_u32 orelse error.NotFound;
        }
        pub fn setU32(self: *@This(), _: []const u8, value: u32) kvs_mod.KvsError!void {
            self.value_u32 = value;
        }
        pub fn getString(self: *@This(), _: []const u8, buf: []u8) kvs_mod.KvsError![]const u8 {
            const s = self.value_str orelse return error.NotFound;
            if (buf.len < s.len) return error.BufferTooSmall;
            @memcpy(buf[0..s.len], s);
            return buf[0..s.len];
        }
        pub fn setString(self: *@This(), _: []const u8, value: []const u8) kvs_mod.KvsError!void {
            self.value_str = value;
        }
        pub fn getI32(self: *@This(), key: []const u8) kvs_mod.KvsError!i32 {
            return @bitCast(try self.getU32(key));
        }
        pub fn setI32(self: *@This(), key: []const u8, value: i32) kvs_mod.KvsError!void {
            return self.setU32(key, @bitCast(value));
        }
        pub fn erase(self: *@This(), _: []const u8) kvs_mod.KvsError!void {
            self.value_u32 = null;
            self.value_str = null;
        }
        pub fn eraseAll(self: *@This()) kvs_mod.KvsError!void {
            self.value_u32 = null;
            self.value_str = null;
        }
        pub fn commit(self: *@This()) kvs_mod.KvsError!void {
            self.commits += 1;
        }
    };

    const Kvs = kvs_mod.from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "kvs.test" };
    });

    var d = Mock{};
    var kvs = Kvs.init(&d);
    try kvs.setU32("cnt", 42);
    try std.testing.expectEqual(@as(u32, 42), try kvs.getU32("cnt"));
    try kvs.setString("name", "abc");
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("abc", try kvs.getString("name", &buf));
    try kvs.commit();
    try std.testing.expectEqual(@as(u32, 1), d.commits);
}
