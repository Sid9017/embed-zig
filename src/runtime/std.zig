//! 兼容入口：std runtime 实现已拆分到 `runtime/std/*`。

const root = @import("std/root.zig");

pub const StdTime = root.StdTime;
pub const StdLog = root.StdLog;
pub const StdRng = root.StdRng;
pub const StdMutex = root.StdMutex;
pub const StdCondition = root.StdCondition;
pub const StdNotify = root.StdNotify;
pub const StdThread = root.StdThread;
pub const StdSystem = root.StdSystem;
pub const StdFs = root.StdFs;
pub const StdIO = root.StdIO;
pub const StdSocket = root.StdSocket;
pub const StdNetIf = root.StdNetIf;
pub const StdOtaBackend = root.StdOtaBackend;
pub const StdCrypto = root.StdCrypto;

pub const StdRuntimeDecl = root.StdRuntimeDecl;
pub const StdRuntime = root.StdRuntime;

test {
    _ = @import("std/tests.zig");
}
