//! Placeholder Quectel module profile for Step 8. Replaced by full quectel.zig in Step 12.
//! Exports the Module namespace contract: commands, urcs, init_sequence.

const base_cmds = @import("../../at/commands.zig");
const types = @import("../../types.zig");

/// Module-specific commands. Expand in Step 12.
pub const commands = struct {
    pub const GetModuleInfo = base_cmds.GetModuleInfo;
};

/// Module-specific URCs. Expand in Step 12.
pub const urcs = struct {
    pub const Creg = @import("../../at/urcs.zig").CregUrc;
};

/// Init sequence: minimal for stub (Probe only).
pub const init_sequence = &[_]type{base_cmds.Probe};
