//! std runtime — validates all std implementations against runtime contracts.

const std = @import("std");

pub const std_time = @import("std/time.zig");
pub const std_log = @import("std/log.zig");
pub const std_rng = @import("std/rng.zig");
pub const std_sync = @import("std/sync.zig");
pub const std_thread = @import("std/thread.zig");
pub const std_system = @import("std/system.zig");
pub const std_fs = @import("std/fs.zig");
pub const std_channel = @import("std/channel.zig");
pub const std_select = @import("std/select.zig");
pub const std_socket = @import("std/socket.zig");
pub const std_netif = @import("std/netif.zig");
pub const std_ota_backend = @import("std/ota_backend.zig");
pub const std_crypto_hash = @import("std/crypto/hash.zig");
pub const std_crypto_hmac = @import("std/crypto/hmac.zig");
pub const std_crypto_hkdf = @import("std/crypto/hkdf.zig");
pub const std_crypto_aead = @import("std/crypto/aead.zig");
pub const std_crypto_pki = @import("std/crypto/pki.zig");
pub const std_crypto_rsa = @import("std/crypto/rsa.zig");
pub const std_crypto_kex = @import("std/crypto/kex.zig");
pub const std_crypto_x509 = @import("std/crypto/x509.zig");

pub const Time = std_time.Time;
pub const Log = std_log.Log;
pub const Rng = std_rng.Rng;
pub const Mutex = std_sync.Mutex;
pub const Condition = std_sync.Condition;
pub const Notify = std_sync.Notify;
pub const Thread = std_thread.Thread;
pub const System = std_system.System;
pub const Fs = std_fs.Fs;
pub const Channel = std_channel.Channel;
pub const Selector = std_select.Selector;
pub const Socket = std_socket.Socket;
pub const NetIf = std_netif.NetIf;
pub const OtaBackend = std_ota_backend.OtaBackend;
pub const Crypto = struct {
    pub const Sha256 = std_crypto_hash.Sha256;
    pub const Sha384 = std_crypto_hash.Sha384;
    pub const Sha512 = std_crypto_hash.Sha512;

    pub const HmacSha256 = std_crypto_hmac.HmacSha256;
    pub const HmacSha384 = std_crypto_hmac.HmacSha384;
    pub const HmacSha512 = std_crypto_hmac.HmacSha512;

    pub const HkdfSha256 = std_crypto_hkdf.HkdfSha256;
    pub const HkdfSha384 = std_crypto_hkdf.HkdfSha384;
    pub const HkdfSha512 = std_crypto_hkdf.HkdfSha512;

    pub const Aes128Gcm = std_crypto_aead.Aes128Gcm;
    pub const Aes256Gcm = std_crypto_aead.Aes256Gcm;
    pub const ChaCha20Poly1305 = std_crypto_aead.ChaCha20Poly1305;

    pub const Ed25519 = std_crypto_pki.Ed25519;
    pub const EcdsaP256Sha256 = std_crypto_pki.EcdsaP256Sha256;
    pub const EcdsaP384Sha384 = std_crypto_pki.EcdsaP384Sha384;

    pub const rsa = std_crypto_rsa.rsa;

    pub const X25519 = std_crypto_kex.X25519;
    pub const P256 = std_crypto_kex.P256;

    pub const Rng = struct {
        pub fn fill(buf: []u8) void {
            std.crypto.random.bytes(buf);
        }
    };

    pub const x509 = std_crypto_x509;
};
