//! Runtime Time Contract

/// Validate whether `T` satisfies the Time contract.
pub fn is(comptime T: type) bool {
    const BaseType = switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };

    switch (@typeInfo(BaseType)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return false,
    }

    if (!@hasDecl(BaseType, "nowMs") or !@hasDecl(BaseType, "sleepMs")) {
        return false;
    }

    return @TypeOf(&BaseType.nowMs) == *const fn () u64 and
        @TypeOf(&BaseType.sleepMs) == *const fn (u32) void;
}

/// Time contract:
/// - `nowMs() -> u64`
/// - `sleepMs(ms: u32) -> void`
pub fn from(comptime Impl: type) type {
    comptime {
        const BaseType = switch (@typeInfo(Impl)) {
            .pointer => |p| p.child,
            else => Impl,
        };

        _ = @as(*const fn () u64, &BaseType.nowMs);
        _ = @as(*const fn (u32) void, &BaseType.sleepMs);
    }
    return Impl;
}

test "is returns false when declarations missing" {
    const Incomplete = struct {
        pub fn nowMs() u64 {
            return 0;
        }
    };
    try @import("std").testing.expect(!is(Incomplete));
}
