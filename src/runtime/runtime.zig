//! Runtime suite contract — aggregates all runtime component contracts.

const time = @import("time.zig");
const log = @import("log.zig");
const rng = @import("rng.zig");
const mutex = @import("sync/mutex.zig");
const condition = @import("sync/condition.zig");
const notify = @import("sync/notify.zig");
const thread = @import("thread.zig");
const system = @import("system.zig");
const fs = @import("fs.zig");
const channel_factory = @import("channel_factory.zig");
const socket = @import("socket.zig");
const ota_backend = @import("ota_backend.zig");
const crypto_suite = @import("crypto/suite.zig");

const Seal = struct {};

/// Construct a sealed Runtime from a backend Impl type.
///
/// Impl must provide:
///   - `Time`, `Log`, `Rng`, `Thread`, `System`, `Fs`, `Socket`, `OtaBackend`
///   - `Mutex`, `Condition`, `Notify` (sync primitives)
///   - `ChannelFactory` (factory function `fn(type) type`)
///   - `Crypto` (crypto suite backend, passed to `crypto.suite.Make`)
pub fn Make(comptime Impl: type) type {
    return struct {
        pub const seal: Seal = .{};

        pub const Time = time.Make(Impl.Time);
        pub const Log = log.Make(Impl.Log);
        pub const Rng = rng.Make(Impl.Rng);
        pub const Mutex = mutex.Make(Impl.Mutex);
        pub const Condition = condition.Make(Impl.Condition, Impl.Mutex);
        pub const Notify = notify.Make(Impl.Notify);
        pub const Thread = thread.Make(Impl.Thread);
        pub const System = system.Make(Impl.System);
        pub const Fs = fs.Make(Impl.Fs);
        pub const ChannelFactory = channel_factory.Make(Impl.ChannelFactory);
        pub const Socket = socket.Make(Impl.Socket);
        pub const OtaBackend = ota_backend.Make(Impl.OtaBackend);
        pub const Crypto = crypto_suite.Make(Impl.Crypto);
    };
}

/// Validate that T has been sealed via Make().
pub fn is(comptime T: type) type {
    comptime {
        if (!@hasDecl(T, "seal") or @TypeOf(T.seal) != Seal) {
            @compileError("Impl must have pub const seal: runtime.Seal — use runtime.Make(Backend) to construct");
        }
    }
    return T;
}
