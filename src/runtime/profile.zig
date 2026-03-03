//! Runtime profiles define minimum capability sets.

const sync = @import("sync.zig");
const time = @import("time.zig");
const log = @import("log.zig");
const rng = @import("rng.zig");
const thread = @import("thread.zig");
const io = @import("io.zig");
const socket = @import("socket.zig");
const fs = @import("fs.zig");
const system = @import("system.zig");
const netif = @import("netif.zig");
const ota_backend = @import("ota_backend.zig");
const crypto = @import("crypto/root.zig");

/// Runtime execution profile.
pub const RuntimeProfile = enum {
    /// Bare minimum runtime (single-thread/cooperative style).
    minimal,
    /// `minimal` + thread support.
    threaded,
    /// `minimal` + IO/socket event loop support.
    evented,
};

fn requireDecl(comptime Rt: type, comptime name: []const u8) void {
    if (!@hasDecl(Rt, name)) {
        @compileError("Runtime missing required declaration: " ++ name);
    }
}

fn validateCommon(comptime Rt: type) void {
    requireDecl(Rt, "Time");
    requireDecl(Rt, "Log");
    requireDecl(Rt, "Rng");
    requireDecl(Rt, "Mutex");
    requireDecl(Rt, "Condition");
    requireDecl(Rt, "Notify");

    _ = time.from(Rt.Time);
    _ = log.from(Rt.Log);
    _ = rng.from(Rt.Rng);
    _ = sync.Mutex(Rt.Mutex);
    _ = sync.ConditionWithMutex(Rt.Condition, Rt.Mutex);
    _ = sync.Notify(Rt.Notify);
}

fn validateOptional(comptime Rt: type) void {
    if (@hasDecl(Rt, "Thread")) _ = thread.from(Rt.Thread);
    if (@hasDecl(Rt, "IO")) _ = io.from(Rt.IO);
    if (@hasDecl(Rt, "Socket")) _ = socket.from(Rt.Socket);
    if (@hasDecl(Rt, "Fs")) _ = fs.from(Rt.Fs);
    if (@hasDecl(Rt, "System")) _ = system.from(Rt.System);
    if (@hasDecl(Rt, "NetIf")) _ = netif.from(Rt.NetIf);
    if (@hasDecl(Rt, "OtaBackend")) _ = ota_backend.from(Rt.OtaBackend);
    if (@hasDecl(Rt, "Crypto")) _ = crypto.from(Rt.Crypto);
}

/// Validate runtime declaration set by profile kind and return `Rt` as-is.
pub fn from(comptime kind: RuntimeProfile, comptime Rt: type) type {
    comptime {
        validateCommon(Rt);

        switch (kind) {
            .minimal => {},
            .threaded => {
                requireDecl(Rt, "Thread");
                _ = thread.from(Rt.Thread);
            },
            .evented => {
                requireDecl(Rt, "IO");
                requireDecl(Rt, "Socket");
                _ = io.from(Rt.IO);
                _ = socket.from(Rt.Socket);

                // evented profile allows optional thread support.
                if (@hasDecl(Rt, "Thread")) _ = thread.from(Rt.Thread);
            },
        }

        // Declaration-presence model for optional modules.
        validateOptional(Rt);
    }
    return Rt;
}
