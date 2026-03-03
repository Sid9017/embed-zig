pub const hash = @import("hash.zig");
pub const hmac = @import("hmac.zig");
pub const hkdf = @import("hkdf.zig");
pub const aead = @import("aead.zig");
pub const pki = @import("pki.zig");
pub const suite = @import("suite.zig");

pub fn from(comptime Impl: type) type {
    return suite.from(Impl);
}
