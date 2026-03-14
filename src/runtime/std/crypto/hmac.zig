const std = @import("std");

pub fn HmacWrapper(comptime StdHmac: type) type {
    return struct {
        pub const mac_length = StdHmac.mac_length;

        inner: StdHmac,

        pub fn create(out: *[mac_length]u8, msg: []const u8, key: []const u8) void {
            StdHmac.create(out, msg, key);
        }

        pub fn init(key: []const u8) @This() {
            return .{ .inner = StdHmac.init(key) };
        }

        pub fn update(self: *@This(), data: []const u8) void {
            self.inner.update(data);
        }

        pub fn final(self: *@This()) [mac_length]u8 {
            var out: [mac_length]u8 = undefined;
            self.inner.final(&out);
            return out;
        }
    };
}

pub const HmacSha256 = HmacWrapper(std.crypto.auth.hmac.sha2.HmacSha256);
pub const HmacSha384 = HmacWrapper(std.crypto.auth.hmac.sha2.HmacSha384);
pub const HmacSha512 = HmacWrapper(std.crypto.auth.hmac.sha2.HmacSha512);
