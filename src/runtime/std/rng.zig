const std = @import("std");
const embed = @import("../../mod.zig");

pub const Rng = struct {
    pub fn fill(_: Rng, buf: []u8) embed.runtime.rng.Error!void {
        std.crypto.random.bytes(buf);
    }
};
