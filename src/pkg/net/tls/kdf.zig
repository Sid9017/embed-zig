const std = @import("std");
pub const runtime = struct {
    pub const std = @import("../../../runtime/std.zig");
};

/// HKDF-Expand-Label for TLS 1.3 (RFC 8446 Section 7.1).
pub fn hkdfExpandLabel(
    comptime Hkdf: type,
    secret: [Hkdf.prk_length]u8,
    comptime label: []const u8,
    context: []const u8,
    comptime len: usize,
) [len]u8 {
    const full_label = "tls13 " ++ label;

    var hkdf_label: [2 + 1 + full_label.len + 1 + 255]u8 = undefined;
    var pos: usize = 0;

    std.mem.writeInt(u16, hkdf_label[pos..][0..2], len, .big);
    pos += 2;

    hkdf_label[pos] = full_label.len;
    pos += 1;
    @memcpy(hkdf_label[pos..][0..full_label.len], full_label);
    pos += full_label.len;

    hkdf_label[pos] = @intCast(context.len);
    pos += 1;
    if (context.len > 0) {
        @memcpy(hkdf_label[pos..][0..context.len], context);
        pos += context.len;
    }

    return Hkdf.expand(&secret, hkdf_label[0..pos], len);
}
