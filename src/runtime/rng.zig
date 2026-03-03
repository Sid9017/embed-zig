//! Runtime RNG Contract

const std = @import("std");

pub const Error = error{
    RngFailed,
};

/// Validate whether `T` satisfies the RNG contract.
pub fn is(comptime T: type) bool {
    const BaseType = switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };

    switch (@typeInfo(BaseType)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return false,
    }

    if (!@hasDecl(BaseType, "fill")) {
        return false;
    }

    return @TypeOf(&BaseType.fill) == *const fn ([]u8) Error!void;
}

/// RNG contract:
/// - `fill(buf: []u8) -> Error!void`
pub fn from(comptime Impl: type) type {
    comptime {
        const BaseType = switch (@typeInfo(Impl)) {
            .pointer => |p| p.child,
            else => Impl,
        };

        _ = @as(*const fn ([]u8) Error!void, &BaseType.fill);
    }
    return Impl;
}

/// Default host RNG implementation.
pub const StdRng = struct {
    pub fn fill(buf: []u8) Error!void {
        std.crypto.random.bytes(buf);
    }
};

test "StdRng fill" {
    var buf: [16]u8 = undefined;
    try StdRng.fill(&buf);
}

test "is returns false when declaration missing" {
    const Incomplete = struct {};
    try std.testing.expect(!is(Incomplete));
}
