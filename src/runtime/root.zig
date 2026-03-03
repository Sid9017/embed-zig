const runtime = @import("runtime.zig");

pub const errors = runtime.errors;
pub const profile = runtime.profile;

pub const sync = runtime.sync;
pub const time = runtime.time;
pub const thread = runtime.thread;
pub const system = runtime.system;
pub const io = runtime.io;
pub const socket = runtime.socket;
pub const fs = runtime.fs;
pub const log = runtime.log;
pub const rng = runtime.rng;
pub const netif = runtime.netif;
pub const ota_backend = runtime.ota_backend;
pub const crypto = runtime.crypto;
pub const std = runtime.std;
pub const std_runtime = runtime.std_runtime;

pub const Runtime = runtime.Runtime;

pub fn from(comptime Rt: type) type {
    return runtime.from(Rt);
}
