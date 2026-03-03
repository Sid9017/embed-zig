//! Runtime crypto hash contracts.

/// Generic hash contract validator.
pub fn from(comptime Impl: type, comptime digest_len: usize) type {
    comptime {
        if (!@hasDecl(Impl, "digest_length") or Impl.digest_length != digest_len) {
            @compileError("Hash.digest_length mismatch");
        }

        _ = @as(*const fn () Impl, &Impl.init);
        _ = @as(*const fn (*Impl, []const u8) void, &Impl.update);
        _ = @as(*const fn (*Impl) [digest_len]u8, &Impl.final);
        _ = @as(*const fn ([]const u8, *[digest_len]u8) void, &Impl.hash);
    }
    return Impl;
}

pub fn Sha256(comptime Impl: type) type {
    return from(Impl, 32);
}

pub fn Sha384(comptime Impl: type) type {
    return from(Impl, 48);
}

pub fn Sha512(comptime Impl: type) type {
    return from(Impl, 64);
}

test "hash contract with mock" {
    const MockHash = struct {
        pub const digest_length = 32;

        pub fn init() @This() {
            return .{};
        }

        pub fn update(_: *@This(), _: []const u8) void {}

        pub fn final(_: *@This()) [32]u8 {
            return [_]u8{0} ** 32;
        }

        pub fn hash(_: []const u8, out: *[32]u8) void {
            out.* = [_]u8{1} ** 32;
        }
    };

    const H = Sha256(MockHash);
    _ = H;
}
