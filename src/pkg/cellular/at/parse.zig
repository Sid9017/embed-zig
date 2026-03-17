//! Pure AT response parsing. No state, no IO, only types.zig.
//! See plan.md §5.3; full implementation in Step 3.

const types = @import("../types.zig");

/// Returns true if the line is "OK".
pub fn isOk(line: []const u8) bool {
    _ = line;
    return false;
}

/// Returns true if the line is "ERROR" (not +CME ERROR).
pub fn isError(line: []const u8) bool {
    _ = line;
    return false;
}

/// Parses "+CME ERROR: N" and returns N.
pub fn parseCmeError(line: []const u8) ?u16 {
    _ = line;
    return null;
}

/// Parses "+CMS ERROR: N" and returns N.
pub fn parseCmsError(line: []const u8) ?u16 {
    _ = line;
    return null;
}

/// Returns the substring after prefix (e.g. "+CSQ: 20,0" with "+CSQ:" -> "20,0").
pub fn parsePrefix(line: []const u8, prefix: []const u8) ?[]const u8 {
    _ = line;
    _ = prefix;
    return null;
}

/// Parses CSQ value into CellularSignalInfo.
pub fn parseCsq(value: []const u8) ?types.CellularSignalInfo {
    _ = value;
    return null;
}

/// Parses CPIN value into SimStatus.
pub fn parseCpin(value: []const u8) ?types.SimStatus {
    _ = value;
    return null;
}

/// Parses CREG/CGREG/CEREG value into CellularRegStatus.
pub fn parseCreg(value: []const u8) ?types.CellularRegStatus {
    _ = value;
    return null;
}

/// Converts CSQ (0–31) to approximate dBm.
pub fn rssiToDbm(csq: u8) i8 {
    _ = csq;
    return -113;
}

/// Converts dBm to 0–100% for display.
pub fn rssiToPercent(dbm: i8) u8 {
    _ = dbm;
    return 0;
}
