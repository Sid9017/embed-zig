//! Runtime System Contract

/// Fixed error set for system queries.
pub const Error = error{
    Unsupported,
    QueryFailed,
};

/// Validate whether `T` satisfies the System contract.
pub fn is(comptime T: type) bool {
    const BaseType = switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };

    switch (@typeInfo(BaseType)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return false,
    }

    if (!@hasDecl(BaseType, "getCpuCount")) {
        return false;
    }

    return @TypeOf(&BaseType.getCpuCount) == *const fn () Error!usize;
}

/// System contract:
/// - `getCpuCount() -> Error!usize`
pub fn from(comptime Impl: type) type {
    comptime {
        const BaseType = switch (@typeInfo(Impl)) {
            .pointer => |p| p.child,
            else => Impl,
        };

        _ = @as(*const fn () Error!usize, &BaseType.getCpuCount);
    }
    return Impl;
}

test "is returns false when declaration missing" {
    const Incomplete = struct {};
    try @import("std").testing.expect(!is(Incomplete));
}
