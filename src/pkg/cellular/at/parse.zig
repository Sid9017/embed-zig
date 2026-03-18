//! Pure AT response parsing. No state, no IO, only types.zig.
//! All functions are pure: input string → parsed result.
//! See plan.md §5.3.

const std = @import("std");
const types = @import("../types.zig");

/// Strip trailing \r (AT responses end with \r\n; after line splitting the \r remains).
fn trimCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

/// Next logical line from AT response body; advances `pos`.
pub fn atBodyNextLine(body: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= body.len) return null;
    const rest = body[pos.*..];
    const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse {
        pos.* = body.len;
        return trimCr(rest);
    };
    const line = rest[0..nl];
    pos.* += nl + 1;
    return trimCr(line);
}

/// First line for which `Cmd.parseResponse` returns non-null.
pub fn parseTypedAtResponse(comptime Cmd: type, body: []const u8) ?(Cmd.Response) {
    comptime {
        _ = Cmd.Response;
        _ = @as(*const fn ([]const u8) ?(Cmd.Response), &Cmd.parseResponse);
    }
    var pos: usize = 0;
    while (true) {
        const line = atBodyNextLine(body, &pos) orelse break;
        if (Cmd.parseResponse(line)) |v| return v;
    }
    return null;
}

/// Returns true if the line is "OK".
pub fn isOk(line: []const u8) bool {
    return std.mem.eql(u8, trimCr(line), "OK");
}

/// Returns true if the line is "ERROR" (not +CME ERROR / +CMS ERROR).
pub fn isError(line: []const u8) bool {
    return std.mem.eql(u8, trimCr(line), "ERROR");
}

/// Parses "+CME ERROR: N" and returns N.
pub fn parseCmeError(line: []const u8) ?u16 {
    return parseErrorWithPrefix(trimCr(line), "+CME ERROR: ");
}

/// Parses "+CMS ERROR: N" and returns N.
pub fn parseCmsError(line: []const u8) ?u16 {
    return parseErrorWithPrefix(trimCr(line), "+CMS ERROR: ");
}

fn parseErrorWithPrefix(line: []const u8, prefix: []const u8) ?u16 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const num_str = std.mem.trim(u8, line[prefix.len..], " ");
    if (num_str.len == 0) return null;
    return std.fmt.parseInt(u16, num_str, 10) catch null;
}

/// Returns the substring after prefix, trimming leading whitespace.
/// e.g. parsePrefix("+CSQ: 20,0", "+CSQ:") returns " 20,0" trimmed to "20,0".
pub fn parsePrefix(line: []const u8, prefix: []const u8) ?[]const u8 {
    const trimmed = trimCr(line);
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const rest = trimmed[prefix.len..];
    return std.mem.trimLeft(u8, rest, " ");
}

/// Parses CSQ response value "rssi,ber" into CellularSignalInfo.
/// rssi 0-31 maps to dBm via rssiToDbm; 99 means not detectable (returns null).
pub fn parseCsq(value: []const u8) ?types.CellularSignalInfo {
    const comma = std.mem.indexOfScalar(u8, value, ',') orelse return null;
    const rssi_str = std.mem.trim(u8, value[0..comma], " ");
    const ber_str = std.mem.trim(u8, value[comma + 1 ..], " \r");

    const rssi_raw = std.fmt.parseInt(u8, rssi_str, 10) catch return null;
    if (rssi_raw == 99) return null;
    if (rssi_raw > 31) return null;

    const ber_raw = std.fmt.parseInt(u8, ber_str, 10) catch return null;

    return .{
        .rssi = rssiToDbm(rssi_raw),
        .ber = if (ber_raw == 99) null else ber_raw,
    };
}

/// Parses CPIN response value into SimStatus.
pub fn parseCpin(value: []const u8) ?types.SimStatus {
    const trimmed = std.mem.trim(u8, value, " \r");
    if (std.mem.eql(u8, trimmed, "READY")) return .ready;
    if (std.mem.eql(u8, trimmed, "SIM PIN")) return .pin_required;
    if (std.mem.eql(u8, trimmed, "SIM PUK")) return .puk_required;
    if (std.mem.eql(u8, trimmed, "NOT INSERTED")) return .not_inserted;
    if (std.mem.eql(u8, trimmed, "SIM ERROR")) return .@"error";
    if (std.mem.eql(u8, trimmed, "NOT READY")) return .not_inserted;
    return null;
}

/// Parses CREG/CGREG/CEREG response value into CellularRegStatus.
/// Format: "n,stat" or just "stat". We take the last numeric field as stat.
pub fn parseCreg(value: []const u8) ?types.CellularRegStatus {
    const trimmed = std.mem.trim(u8, value, " \r");
    // Take the stat field: after the last comma, or the whole string if no comma
    const stat_str = if (std.mem.lastIndexOfScalar(u8, trimmed, ',')) |pos|
        std.mem.trim(u8, trimmed[pos + 1 ..], " ")
    else
        trimmed;

    const stat = std.fmt.parseInt(u8, stat_str, 10) catch return null;
    return switch (stat) {
        0 => .not_registered,
        1 => .registered_home,
        2 => .searching,
        3 => .denied,
        5 => .registered_roaming,
        else => .unknown,
    };
}

/// Parses an IMEI string from AT+CGSN response. IMEI is exactly 15 digits (3GPP TS 23.003).
pub fn parseImei(line: []const u8) ?[]const u8 {
    return parseDigitString(line, 15, 15);
}

/// Parses an IMSI string from AT+CIMI response. IMSI is 6-15 digits (3GPP TS 23.003).
pub fn parseImsi(line: []const u8) ?[]const u8 {
    return parseDigitString(line, 6, 15);
}

/// Parses an ICCID string (ITU-T E.118, 18-22 digits).
pub fn parseIccid(line: []const u8) ?[]const u8 {
    return parseDigitString(line, 18, 22);
}

fn parseDigitString(line: []const u8, min_len: usize, max_len: usize) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \r\n");
    if (trimmed.len < min_len or trimmed.len > max_len) return null;
    for (trimmed) |c| {
        if (c < '0' or c > '9') return null;
    }
    return trimmed;
}

/// Converts CSQ (0–31) to approximate dBm. Formula: -113 + 2*csq (3GPP TS 27.007).
pub fn rssiToDbm(csq: u8) i8 {
    if (csq > 31) return -113;
    return @as(i8, -113) + @as(i8, @intCast(csq)) * 2;
}

/// Converts dBm to 0–100% for display. Linear mapping: -113 dBm = 0%, -51 dBm = 100%.
pub fn rssiToPercent(dbm: i8) u8 {
    if (dbm <= -113) return 0;
    if (dbm >= -51) return 100;
    // Range is 62 dBm (-113 to -51). Scale to 0-100.
    const offset: u8 = @intCast(dbm - (-113));
    return @intCast((@as(u16, offset) * 100) / 62);
}

/// Last complete terminal line in an AT RX buffer (OK / ERROR / +CME / +CMS).
pub const AtRxTerminal = struct {
    pub const Kind = enum { ok, gen_error, cme_error, cms_error };
    kind: Kind,
    error_code: ?u16 = null,
    body_end: usize,
};

/// Returns null until a full line ending with `\n` completes a terminal response.
pub fn scanAtTerminal(rx: []const u8) ?AtRxTerminal {
    var last: ?AtRxTerminal = null;
    var line_start: usize = 0;
    var seg_it = std.mem.splitScalar(u8, rx, '\n');
    while (seg_it.next()) |segment| {
        const line = trimCr(segment);
        if (line.len != 0) {
            if (isOk(line)) {
                last = .{ .kind = .ok, .body_end = line_start };
            } else if (isError(line)) {
                last = .{ .kind = .gen_error, .body_end = line_start };
            } else {
                if (parseCmeError(line)) |code| {
                    last = .{ .kind = .cme_error, .error_code = code, .body_end = line_start };
                } else if (parseCmsError(line)) |code2| {
                    last = .{ .kind = .cms_error, .error_code = code2, .body_end = line_start };
                }
            }
        }
        line_start += segment.len + 1;
    }
    return last;
}
