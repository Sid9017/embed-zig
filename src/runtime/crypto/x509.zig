//! Runtime crypto X.509 contracts.

const std = @import("std");

const Seal = struct {};

pub const VerifyError = error{
    CertificateVerificationFailed,
    CertificateHostMismatch,
    CertificateParseError,
    CertificateChainTooShort,
};

pub fn Make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn (std.mem.Allocator) anyerror!Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(
            *const fn (*Impl, []const []const u8, ?[]const u8, i64) VerifyError!void,
            &Impl.verifyChain,
        );
    }

    return struct {
        pub const seal: Seal = .{};
        pub const BackendType = Impl;

        impl: Impl,

        pub fn init(allocator: std.mem.Allocator) !@This() {
            return .{ .impl = try Impl.init(allocator) };
        }

        pub fn deinit(self: *@This()) void {
            self.impl.deinit();
        }

        pub fn verifyChain(
            self: *@This(),
            chain: []const []const u8,
            hostname: ?[]const u8,
            now_sec: i64,
        ) VerifyError!void {
            return self.impl.verifyChain(chain, hostname, now_sec);
        }
    };
}

pub fn is(comptime T: type) type {
    comptime {
        if (!@hasDecl(T, "seal") or @TypeOf(T.seal) != Seal) {
            @compileError("Impl must have pub const seal: x509.Seal — use x509.Make(Backend) to construct");
        }
    }
    return T;
}
