const std = @import("std");

fn HashWrapper(comptime StdHash: type) type {
    return struct {
        pub const digest_length = StdHash.digest_length;

        inner: StdHash,

        pub fn init() @This() {
            return .{ .inner = StdHash.init(.{}) };
        }

        pub fn update(self: *@This(), data: []const u8) void {
            self.inner.update(data);
        }

        pub fn final(self: *@This()) [digest_length]u8 {
            var out: [digest_length]u8 = undefined;
            self.inner.final(&out);
            return out;
        }

        pub fn hash(data: []const u8, out: *[digest_length]u8) void {
            StdHash.hash(data, out, .{});
        }
    };
}

pub fn hash(comptime digest_len: usize) type {
    return switch (digest_len) {
        32 => HashWrapper(std.crypto.hash.sha2.Sha256),
        48 => HashWrapper(std.crypto.hash.sha2.Sha384),
        64 => HashWrapper(std.crypto.hash.sha2.Sha512),
        else => @compileError("unsupported hash digest length"),
    };
}
