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

/// ATE0 — disable command echo (typical first step after probe).
pub const SetEchoOff = struct {
    pub const Response = void;
    pub const prefix: []const u8 = "";
    pub const timeout_ms: u32 = 2000;

    pub fn write(buf: []u8) usize {
        const cmd = "ATE0\r\n";
        if (cmd.len > buf.len) return 0;
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }

    pub fn parseResponse(_: []const u8) ?Response {
        return null;
    }
};

/// AT+CMEE=2 — enable verbose +CME ERROR: <n> (numeric) responses.
pub const SetCmeErrorVerbose = struct {
    pub const Response = void;
    pub const prefix: []const u8 = "";
    pub const timeout_ms: u32 = 2000;

    pub fn write(buf: []u8) usize {
        const cmd = "AT+CMEE=2\r\n";
        if (cmd.len > buf.len) return 0;
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }

    pub fn parseResponse(_: []const u8) ?Response {
        return null;
    }
};

/// AT+CPIN? — SIM PIN state.
pub const GetCpin = struct {
    pub const Response = types.SimStatus;
    pub const prefix: []const u8 = "+CPIN:";
    pub const timeout_ms: u32 = 5000;

    pub fn write(buf: []u8) usize {
        const cmd = "AT+CPIN?\r\n";
        if (cmd.len > buf.len) return 0;
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }

    pub fn parseResponse(line: []const u8) ?Response {
        const val = parse.parsePrefix(line, "+CPIN:") orelse return null;
        return parse.parseCpin(val);
    }
};

/// AT+CEREG? — EPS (LTE) registration status.
pub const GetCereg = struct {
    pub const Response = types.CellularRegStatus;
    pub const prefix: []const u8 = "+CEREG:";
    pub const timeout_ms: u32 = 5000;

    pub fn write(buf: []u8) usize {
        const cmd = "AT+CEREG?\r\n";
        if (cmd.len > buf.len) return 0;
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }

    pub fn parseResponse(line: []const u8) ?Response {
        const val = parse.parsePrefix(line, "+CEREG:") orelse return null;
        return parse.parseCreg(val);
    }
};

/// AT+CREG? — CS domain registration (2G/3G); same stat encoding as CEREG for tick path.
pub const GetCreg = struct {
    pub const Response = types.CellularRegStatus;
    pub const prefix: []const u8 = "+CREG:";
    pub const timeout_ms: u32 = 5000;

    pub fn write(buf: []u8) usize {
        const cmd = "AT+CREG?\r\n";
        if (cmd.len > buf.len) return 0;
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }

    pub fn parseResponse(line: []const u8) ?Response {
        const val = parse.parsePrefix(line, "+CREG:") orelse return null;
        return parse.parseCreg(val);
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

/// AT+CGSN — read IMEI (International Mobile Equipment Identity, 15 digits).
pub const GetImei = struct {
    pub const Response = []const u8;
    pub const prefix: []const u8 = "";
    pub const timeout_ms: u32 = 5000;

    pub fn write(buf: []u8) usize {
        const cmd = "AT+CGSN\r\n";
        if (cmd.len > buf.len) return 0;
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }

    pub fn parseResponse(line: []const u8) ?Response {
        return parse.parseImei(line);
    }
};

/// AT+CIMI — read IMSI (International Mobile Subscriber Identity).
pub const GetImsi = struct {
    pub const Response = []const u8;
    pub const prefix: []const u8 = "";
    pub const timeout_ms: u32 = 5000;

    pub fn write(buf: []u8) usize {
        const cmd = "AT+CIMI\r\n";
        if (cmd.len > buf.len) return 0;
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }

    pub fn parseResponse(line: []const u8) ?Response {
        return parse.parseImsi(line);
    }
};

/// AT+CCID — read ICCID (Integrated Circuit Card Identifier).
pub const GetIccid = struct {
    pub const Response = []const u8;
    pub const prefix: []const u8 = "+CCID:";
    pub const timeout_ms: u32 = 5000;

    pub fn write(buf: []u8) usize {
        const cmd = "AT+CCID\r\n";
        if (cmd.len > buf.len) return 0;
        @memcpy(buf[0..cmd.len], cmd);
        return cmd.len;
    }

    /// Handles both `+CCID: <iccid>` and bare `<iccid>` response formats.
    pub fn parseResponse(line: []const u8) ?Response {
        if (parse.parsePrefix(line, "+CCID:")) |val| {
            return parse.parseIccid(val);
        }
        return parse.parseIccid(line);
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
