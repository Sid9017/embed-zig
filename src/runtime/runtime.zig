pub const errors = @import("errors.zig");
pub const profile = @import("profile.zig");

pub const sync = @import("sync.zig");
pub const time = @import("time.zig");
pub const thread = @import("thread.zig");
pub const system = @import("system.zig");
pub const io = @import("io.zig");
pub const socket = @import("socket.zig");
pub const fs = @import("fs.zig");
pub const log = @import("log.zig");
pub const rng = @import("rng.zig");
pub const netif = @import("netif.zig");
pub const ota_backend = @import("ota_backend.zig");
pub const crypto = @import("crypto/root.zig");
pub const std = @import("std/root.zig");
pub const std_runtime = @import("std/root.zig");

/// Runtime 聚合入口。
pub const Runtime = struct {
    /// Validate and return the runtime struct itself.
    pub fn from(comptime Rt: type) type {
        comptime {
            if (!@hasDecl(Rt, "Profile")) {
                @compileError("Runtime missing required declaration: Profile");
            }
            if (@TypeOf(Rt.Profile) != profile.RuntimeProfile) {
                @compileError("Runtime.Profile must be runtime.profile.RuntimeProfile");
            }
        }

        return profile.from(Rt.Profile, Rt);
    }
};

/// Convenience alias: `runtime.from(Rt)` == `runtime.Runtime.from(Rt)`.
pub fn from(comptime Rt: type) type {
    return Runtime.from(Rt);
}
