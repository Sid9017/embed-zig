//! std runtime — validates all std implementations against runtime contracts.

// const std = @import("std");
const runtime = struct {
    pub const channel_factory = @import("channel_factory.zig");
    pub const condition = @import("sync/condition.zig");
    pub const fs = @import("fs.zig");
    pub const log = @import("log.zig");
    pub const mutex = @import("sync/mutex.zig");
    pub const notify = @import("sync/notify.zig");
    pub const ota_backend = @import("ota_backend.zig");
    pub const rng = @import("rng.zig");
    pub const socket = @import("socket.zig");
    pub const system = @import("system.zig");
    pub const thread = @import("thread.zig");
    pub const time = @import("time.zig");
    pub const sync = struct {
        pub const condition = @import("sync/condition.zig");
        pub const mutex = @import("sync/mutex.zig");
        pub const notify = @import("sync/notify.zig");
    };
    pub const crypto = struct {
        pub const hash = @import("crypto/hash.zig");
        pub const hmac = @import("crypto/hmac.zig");
        pub const hkdf = @import("crypto/hkdf.zig");
        pub const aead = @import("crypto/aead.zig");
        pub const pki = @import("crypto/pki.zig");
        pub const suite = @import("crypto/suite.zig");
    };
};

const std = struct {
    pub const channel_factory = @import("std/channel_factory.zig");
    pub const condition = @import("std/sync/condition.zig");
    pub const fs = @import("std/fs.zig");
    pub const log = @import("std/log.zig");
    pub const mutex = @import("std/sync/mutex.zig");
    pub const notify = @import("std/sync/notify.zig");
    pub const ota_backend = @import("std/ota_backend.zig");
    pub const rng = @import("std/rng.zig");
    pub const socket = @import("std/socket.zig");
    pub const system = @import("std/system.zig");
    pub const thread = @import("std/thread.zig");
    pub const time = @import("std/time.zig");
    pub const sync = struct {
        pub const condition = @import("std/sync/condition.zig");
        pub const mutex = @import("std/sync/mutex.zig");
        pub const notify = @import("std/sync/notify.zig");
    };
    pub const crypto = struct {
        pub const suite = @import("std/crypto/suite.zig");
    };
};

pub const Time = runtime.time.Make(std.time.Time);
pub const Log = runtime.log.Make(std.log.Log);
pub const Rng = runtime.rng.Make(std.rng.Rng);
pub const Mutex = runtime.sync.mutex.Make(std.sync.mutex.Mutex);
pub const Condition = runtime.sync.condition.Make(std.sync.condition.Condition, std.sync.mutex.Mutex);
pub const Notify = runtime.sync.notify.Make(std.sync.notify.Notify);
pub const Thread = runtime.thread.Make(std.thread.Thread);
pub const System = runtime.system.Make(std.system.System);
pub const Fs = runtime.fs.Make(std.fs.Fs);
pub const ChannelFactory = runtime.channel_factory.Make(std.channel_factory.ChannelFactory);
pub const Socket = runtime.socket.Make(std.socket.Socket);
pub const OtaBackend = runtime.ota_backend.Make(std.ota_backend.OtaBackend);
pub const Crypto = runtime.crypto.suite.Make(std.crypto.suite);
