const std = @import("std");
const embed = @import("embed");
const module = embed.runtime.std;
const Time = module.Time;
const Log = module.Log;
const Rng = module.Rng;
const Mutex = module.Mutex;
const Condition = module.Condition;
const Notify = module.Notify;
const Thread = module.Thread;
const System = module.System;
const Fs = module.Fs;
const Socket = module.Socket;
const OtaBackend = module.OtaBackend;
const Crypto = module.Crypto;
const std_time = module.std_time;
const std_log = module.std_log;
const std_rng = module.std_rng;
const std_sync = module.std_sync;
const std_thread = module.std_thread;
const std_system = module.std_system;
const std_fs = module.std_fs;
const std_socket = module.std_socket;
const std_ota_backend = module.std_ota_backend;
const std_crypto_hash = module.std_crypto_hash;
const std_crypto_hmac = module.std_crypto_hmac;
const std_crypto_hkdf = module.std_crypto_hkdf;
const std_crypto_aead = module.std_crypto_aead;
const std_crypto_pki = module.std_crypto_pki;
const std_crypto_rsa = module.std_crypto_rsa;
const std_crypto_kex = module.std_crypto_kex;
const std_crypto_x509 = module.std_crypto_x509;

const time_mod = embed.runtime.time;
const log_mod = embed.runtime.log;
const rng_mod = embed.runtime.rng;
const mutex_mod = embed.runtime.sync.mutex;
const condition_mod = embed.runtime.sync.condition;
const notify_mod = embed.runtime.sync.notify;
const thread_mod = embed.runtime.thread;
const system_mod = embed.runtime.system;
const socket_mod = embed.runtime.socket;
const fs_mod = embed.runtime.fs;
const ota_backend_mod = embed.runtime.ota_backend;
const crypto_mod = embed.runtime.crypto.suite;

test "std implementations satisfy all runtime contracts" {
    _ = time_mod.is(Time);
    _ = log_mod.is(Log);
    _ = rng_mod.is(Rng);
    _ = mutex_mod.is(Mutex);
    _ = condition_mod.is(Condition);
    _ = notify_mod.is(Notify);
    _ = thread_mod.is(Thread);
    _ = system_mod.is(System);
    _ = socket_mod.from(Socket);
    _ = fs_mod.is(Fs);
    _ = ota_backend_mod.is(OtaBackend);
    _ = crypto_mod.from(Crypto);
}

test {
    _ = @import("std/tests_test.zig");
}
