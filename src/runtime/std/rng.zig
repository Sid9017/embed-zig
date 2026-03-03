const std = @import("std");
const runtime = @import("../runtime.zig");

pub const StdRng = struct {
    pub fn fill(buf: []u8) runtime.rng.Error!void {
        std.crypto.random.bytes(buf);
    }
};
