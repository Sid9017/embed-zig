//! std runtime — validates all std implementations against runtime contracts.

const std = @import("std");
const runtime_thread = @import("thread.zig");
const runtime_time = @import("time.zig");
const runtime_log = @import("log.zig");
const runtime_mutex = @import("sync/mutex.zig");
const runtime_condition = @import("sync/condition.zig");
const runtime_notify = @import("sync/notify.zig");
const runtime_channel_factory = @import("channel_factory.zig");

pub const std_time = @import("std/time.zig");
pub const std_log = @import("std/log.zig");
pub const std_rng = @import("std/rng.zig");
pub const std_sync = struct {
    pub const Mutex = @import("std/sync/mutex.zig").Mutex;
    pub const Condition = @import("std/sync/condition.zig").Condition;
    pub const Notify = @import("std/sync/notify.zig").Notify;
};
pub const std_thread = @import("std/thread.zig");
pub const std_system = @import("std/system.zig");
pub const std_fs = @import("std/fs.zig");
pub const std_channel_factory = @import("std/channel_factory.zig");
pub const std_socket = @import("std/socket.zig");
pub const std_ota_backend = @import("std/ota_backend.zig");
pub const std_crypto_suite = @import("std/crypto/suite.zig");
pub const std_crypto_hash = @import("std/crypto/hash.zig");
pub const std_crypto_hmac = @import("std/crypto/hmac.zig");
pub const std_crypto_hkdf = @import("std/crypto/hkdf.zig");
pub const std_crypto_aead = @import("std/crypto/aead.zig");
pub const std_crypto_pki = @import("std/crypto/pki.zig");
pub const std_crypto_rsa = @import("std/crypto/rsa.zig");
pub const std_crypto_kex = @import("std/crypto/kex.zig");
pub const std_crypto_x509 = @import("std/crypto/x509.zig");

pub const Time = runtime_time.Time(std_time.Time);
pub const Log = runtime_log.Log(std_log.Log);
pub const Rng = std_rng.Rng;
pub const Mutex = runtime_mutex.Mutex(std_sync.Mutex);
pub const Condition = runtime_condition.Condition(std_sync.Condition, std_sync.Mutex);
pub const Notify = runtime_notify.Notify(std_sync.Notify);
pub const Thread = runtime_thread.Thread(std_thread.Thread);
pub const System = std_system.System;
pub const Fs = std_fs.Fs;
pub const ChannelFactory = runtime_channel_factory.ChannelFactory(std_channel_factory.ChannelFactory);
pub const Socket = std_socket.Socket;
pub const OtaBackend = std_ota_backend.OtaBackend;
pub const Crypto = std_crypto_suite.Crypto;
