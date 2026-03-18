//! std runtime — validates all std implementations against runtime contracts.

const runtime_suite = @import("runtime.zig");

const impl = struct {
    pub const Time = @import("std/time.zig").Time;
    pub const Log = @import("std/log.zig").Log;
    pub const Rng = @import("std/rng.zig").Rng;
    pub const Mutex = @import("std/sync/mutex.zig").Mutex;
    pub const Condition = @import("std/sync/condition.zig").Condition;
    pub const Notify = @import("std/sync/notify.zig").Notify;
    pub const Thread = @import("std/thread.zig").Thread;
    pub const System = @import("std/system.zig").System;
    pub const Fs = @import("std/fs.zig").Fs;
    pub const ChannelFactory = @import("std/channel_factory.zig").ChannelFactory;
    pub const Socket = @import("std/socket.zig").Socket;
    pub const OtaBackend = @import("std/ota_backend.zig").OtaBackend;
    pub const Crypto = @import("std/crypto/suite.zig");
};

pub const Std = runtime_suite.Make(impl);
