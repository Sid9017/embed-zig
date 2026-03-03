//! Runtime OTA backend contract (transport/storage primitives only).

pub const Error = error{
    InitFailed,
    OpenFailed,
    WriteFailed,
    FinalizeFailed,
    AbortFailed,
};

/// OTA backend contract:
/// - `init() -> Error!Impl`
/// - `begin(self: *Impl, image_size: u32) -> Error!void`
/// - `write(self: *Impl, chunk: []const u8) -> Error!void`
/// - `finalize(self: *Impl) -> Error!void`
/// - `abort(self: *Impl) -> void`
pub fn from(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () Error!Impl, &Impl.init);
        _ = @as(*const fn (*Impl, u32) Error!void, &Impl.begin);
        _ = @as(*const fn (*Impl, []const u8) Error!void, &Impl.write);
        _ = @as(*const fn (*Impl) Error!void, &Impl.finalize);
        _ = @as(*const fn (*Impl) void, &Impl.abort);
    }
    return Impl;
}
