//! std runtime 子模块入口。

const runtime = @import("../runtime.zig");
const time = @import("time.zig");
const log = @import("log.zig");
const rng = @import("rng.zig");
const sync = @import("sync.zig");
const thread = @import("thread.zig");
const system = @import("system.zig");
const fs = @import("fs.zig");
const io = @import("io.zig");
const socket = @import("socket.zig");
const netif = @import("netif.zig");
const ota_backend = @import("ota_backend.zig");

pub const StdTime = time.StdTime;
pub const StdLog = log.StdLog;
pub const StdRng = rng.StdRng;
pub const StdMutex = sync.StdMutex;
pub const StdCondition = sync.StdCondition;
pub const StdNotify = sync.StdNotify;
pub const StdThread = thread.StdThread;
pub const StdSystem = system.StdSystem;
pub const StdFs = fs.StdFs;
pub const StdIO = io.StdIO;
pub const StdSocket = socket.StdSocket;
pub const StdNetIf = netif.StdNetIf;
pub const StdOtaBackend = ota_backend.StdOtaBackend;
pub const StdCrypto = @import("crypto/root.zig");

pub const StdRuntimeDecl = struct {
    pub const Profile = runtime.profile.RuntimeProfile.evented;
    pub const Time = StdTime;
    pub const Log = StdLog;
    pub const Rng = StdRng;
    pub const Mutex = StdMutex;
    pub const Condition = StdCondition;
    pub const Notify = StdNotify;
    pub const Thread = StdThread;
    pub const IO = StdIO;
    pub const Socket = StdSocket;
    pub const Fs = StdFs;
    pub const System = StdSystem;
    pub const NetIf = StdNetIf;
    pub const OtaBackend = StdOtaBackend;
    pub const Crypto = StdCrypto;
};

pub const StdRuntime = runtime.from(StdRuntimeDecl);
