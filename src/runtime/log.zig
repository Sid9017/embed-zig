//! Runtime Log Contract

/// Log level used by sinks/backends.
pub const Level = enum {
    debug,
    info,
    warn,
    err,
};

/// Log contract:
/// - `debug(msg: []const u8) -> void`
/// - `info(msg: []const u8) -> void`
/// - `warn(msg: []const u8) -> void`
/// - `err(msg: []const u8) -> void`
pub fn from(comptime Impl: type) type {
    comptime {
        const BaseType = switch (@typeInfo(Impl)) {
            .pointer => |p| p.child,
            else => Impl,
        };

        _ = @as(*const fn ([]const u8) void, &BaseType.debug);
        _ = @as(*const fn ([]const u8) void, &BaseType.info);
        _ = @as(*const fn ([]const u8) void, &BaseType.warn);
        _ = @as(*const fn ([]const u8) void, &BaseType.err);
    }

    return Impl;
}

/// Fast boolean check for contract conformance.
pub fn is(comptime T: type) bool {
    const BaseType = switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };

    switch (@typeInfo(BaseType)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return false,
    }

    if (!@hasDecl(BaseType, "debug") or
        !@hasDecl(BaseType, "info") or
        !@hasDecl(BaseType, "warn") or
        !@hasDecl(BaseType, "err"))
    {
        return false;
    }

    return @TypeOf(&BaseType.debug) == *const fn ([]const u8) void and
        @TypeOf(&BaseType.info) == *const fn ([]const u8) void and
        @TypeOf(&BaseType.warn) == *const fn ([]const u8) void and
        @TypeOf(&BaseType.err) == *const fn ([]const u8) void;
}

test "is returns false when declarations missing" {
    const Incomplete = struct {
        pub fn info(_: []const u8) void {}
    };
    try @import("std").testing.expect(!is(Incomplete));
}
