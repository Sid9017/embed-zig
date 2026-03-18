//! Runtime Log Contract

const std = @import("std");

pub const Level = enum {
    debug,
    info,
    warn,
    err,
};

pub const Seal = struct {};

/// Construct a Log wrapper from an Impl type.
/// Impl must provide: debug, info, warn, err — all `fn(Impl, []const u8) void`.
/// The returned type also provides debugFmt/infoFmt/warnFmt/errFmt convenience methods.
pub fn Make(comptime Impl: type) type {
    const LogType = struct {
        const impl: Impl = .{};
        pub const seal: Seal = .{};

        pub fn debug(_: @This(), msg: []const u8) void {
            impl.debug(msg);
        }

        pub fn info(_: @This(), msg: []const u8) void {
            impl.info(msg);
        }

        pub fn warn(_: @This(), msg: []const u8) void {
            impl.warn(msg);
        }

        pub fn err(_: @This(), msg: []const u8) void {
            impl.err(msg);
        }

        pub fn debugFmt(_: @This(), comptime fmt: []const u8, args: anytype) void {
            logFmt(.debug, fmt, args);
        }

        pub fn infoFmt(_: @This(), comptime fmt: []const u8, args: anytype) void {
            logFmt(.info, fmt, args);
        }

        pub fn warnFmt(_: @This(), comptime fmt: []const u8, args: anytype) void {
            logFmt(.warn, fmt, args);
        }

        pub fn errFmt(_: @This(), comptime fmt: []const u8, args: anytype) void {
            logFmt(.err, fmt, args);
        }

        fn logFmt(comptime level: Level, comptime fmt: []const u8, args: anytype) void {
            var buf: [384]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch {
                const fallback = "[log] format overflow";
                switch (level) {
                    .debug => impl.debug(fallback),
                    .info => impl.info(fallback),
                    .warn => impl.warn(fallback),
                    .err => impl.err(fallback),
                }
                return;
            };
            switch (level) {
                .debug => impl.debug(msg),
                .info => impl.info(msg),
                .warn => impl.warn(msg),
                .err => impl.err(msg),
            }
        }
    };
    return is(LogType);
}

/// Validate that Impl satisfies the Log contract and return it.
pub fn is(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "seal") or @TypeOf(Impl.seal) != Seal) {
            @compileError("Impl must have pub const seal: log.Seal — use log.Make(Backend) to construct");
        }
    }

    return Impl;
}
