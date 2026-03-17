//! Typed URC (unsolicited result code) definitions. Each URC is a struct with prefix + parse.
//! See plan.md R29; full set in Step 4 and module profiles.

const types = @import("../types.zig");

/// Placeholder URC type for compilation. Real URCs (e.g. +CREG, +CPIN) in Step 4 / modem profiles.
pub const CregUrc = struct {
    pub const prefix: []const u8 = "+CREG:";

    pub fn parse(line: []const u8) ?types.CellularRegStatus {
        _ = line;
        return null;
    }
};
