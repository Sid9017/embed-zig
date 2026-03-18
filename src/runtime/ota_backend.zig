//! Runtime OTA backend contract (write + confirm/rollback lifecycle).

pub const Error = error{
    InitFailed,
    OpenFailed,
    WriteFailed,
    FinalizeFailed,
    AbortFailed,
    ConfirmFailed,
    RollbackFailed,
};

pub const State = enum {
    unknown,
    pending_verify,
    valid,
    invalid,
};

const Seal = struct {};

/// Construct a sealed OtaBackend wrapper from a backend Impl type.
/// Impl must provide: init, begin, write, finalize, abort, confirm, rollback, getState.
pub fn Make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () Error!Impl, &Impl.init);
        _ = @as(*const fn (*Impl, u32) Error!void, &Impl.begin);
        _ = @as(*const fn (*Impl, []const u8) Error!void, &Impl.write);
        _ = @as(*const fn (*Impl) Error!void, &Impl.finalize);
        _ = @as(*const fn (*Impl) void, &Impl.abort);
        _ = @as(*const fn (*Impl) Error!void, &Impl.confirm);
        _ = @as(*const fn (*Impl) Error!void, &Impl.rollback);
        _ = @as(*const fn (*Impl) State, &Impl.getState);
    }

    const OtaType = struct {
        impl: Impl,
        pub const seal: Seal = .{};
        pub const BackendType = Impl;

        pub fn init() Error!@This() {
            return .{ .impl = try Impl.init() };
        }

        pub fn begin(self: *@This(), image_size: u32) Error!void {
            return self.impl.begin(image_size);
        }

        pub fn write(self: *@This(), chunk: []const u8) Error!void {
            return self.impl.write(chunk);
        }

        pub fn finalize(self: *@This()) Error!void {
            return self.impl.finalize();
        }

        pub fn abort(self: *@This()) void {
            self.impl.abort();
        }

        pub fn confirm(self: *@This()) Error!void {
            return self.impl.confirm();
        }

        pub fn rollback(self: *@This()) Error!void {
            return self.impl.rollback();
        }

        pub fn getState(self: *@This()) State {
            return self.impl.getState();
        }
    };
    return is(OtaType);
}

/// Validate that Impl satisfies the sealed OtaBackend contract.
pub fn is(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "seal") or @TypeOf(Impl.seal) != Seal) {
            @compileError("Impl must have pub const seal: ota_backend.Seal — use ota_backend.Make(Backend) to construct");
        }
    }
    return Impl;
}
