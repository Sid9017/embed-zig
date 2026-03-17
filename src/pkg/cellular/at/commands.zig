//! Typed AT command definitions (comptime structs with Response, prefix, timeout, write/parse).
//! See plan.md §5.4 and R28. Full set in Step 4.

const types = @import("../types.zig");
const parse = @import("parse.zig");

/// Placeholder probe command for module detection.
pub const Probe = struct {
    pub const Response = void;
    pub const prefix: []const u8 = "";
    pub const timeout_ms: u32 = 2000;

    pub fn write(buf: []u8) usize {
        const cmd = "AT\r\n";
        const n = @min(cmd.len, buf.len);
        @memcpy(buf[0..n], cmd[0..n]);
        return cmd.len;
    }

    pub fn parseResponse(line: []const u8) ?Response {
        _ = line;
        return {};
    }
};

/// Get module identity (CGMM/CGMR/CGSN). Response type per plan; expand in Step 4.
pub const GetModuleInfo = struct {
    pub const Response = types.ModemInfo;
    pub const prefix: []const u8 = "";
    pub const timeout_ms: u32 = 2000;

    pub fn write(buf: []u8) usize {
        const cmd = "ATI\r\n";
        const n = @min(cmd.len, buf.len);
        @memcpy(buf[0..n], cmd[0..n]);
        return cmd.len;
    }

    pub fn parseResponse(line: []const u8) ?Response {
        _ = line;
        return null;
    }
};
