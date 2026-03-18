//! Typed AT command definitions (comptime structs with Response, prefix, timeout, write/parse).
//! See plan.md §5.4.

const types = @import("../types.zig");
const parse = @import("parse.zig");

/// AT probe; response is void on OK.
pub const Probe = struct {
    pub const Response = void;
    pub const prefix: []const u8 = "";
    pub const timeout_ms: u32 = 2000;

    pub fn write(buf: []u8) usize {
        const cmd = "AT\r\n";
        if (cmd.len > buf.len) return 0;
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }

    pub fn parseResponse(_: []const u8) ?Response {
        return null;
    }
};

/// AT+CSQ — signal quality.
pub const GetSignalQuality = struct {
    pub const Response = types.CellularSignalInfo;
    pub const prefix: []const u8 = "+CSQ:";
    pub const timeout_ms: u32 = 5000;

    pub fn write(buf: []u8) usize {
        const cmd = "AT+CSQ\r\n";
        if (cmd.len > buf.len) return 0;
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }

    pub fn parseResponse(line: []const u8) ?Response {
        const val = parse.parsePrefix(line, "+CSQ:") orelse return null;
        return parse.parseCsq(val);
    }
};

/// Module info (placeholder parse until Step 12).
pub const GetModuleInfo = struct {
    pub const Response = types.ModemInfo;
    pub const prefix: []const u8 = "";
    pub const timeout_ms: u32 = 2000;

    pub fn write(buf: []u8) usize {
        const cmd = "ATI\r\n";
        if (cmd.len > buf.len) return 0;
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }

    pub fn parseResponse(_: []const u8) ?Response {
        return null;
    }
};
