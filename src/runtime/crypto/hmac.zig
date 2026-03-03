//! Runtime crypto HMAC contracts.

/// Generic HMAC contract validator.
pub fn from(comptime Impl: type, comptime mac_len: usize) type {
    comptime {
        if (!@hasDecl(Impl, "mac_length") or Impl.mac_length != mac_len) {
            @compileError("HMAC.mac_length mismatch");
        }

        _ = @as(*const fn (*[mac_len]u8, []const u8, []const u8) void, &Impl.create);
        _ = @as(*const fn ([]const u8) Impl, &Impl.init);
        _ = @as(*const fn (*Impl, []const u8) void, &Impl.update);
        _ = @as(*const fn (*Impl) [mac_len]u8, &Impl.final);
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

test "hmac contract with mock" {
    const MockHmac = struct {
        pub const mac_length = 32;

        pub fn create(out: *[32]u8, _: []const u8, _: []const u8) void {
            out.* = [_]u8{2} ** 32;
        }

        pub fn init(_: []const u8) @This() {
            return .{};
        }

        pub fn update(_: *@This(), _: []const u8) void {}

        pub fn final(_: *@This()) [32]u8 {
            return [_]u8{2} ** 32;
        }
    };

    const H = Sha256(MockHmac);
    _ = H;
}
