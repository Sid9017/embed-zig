//! SIMCom module profile: commands, URCs, init_sequence. Full implementation in Step 12.
//! See plan.md §5.11.

const base_cmds = @import("../../at/commands.zig");
const types = @import("../../types.zig");

pub const commands = struct {
    pub const GetModuleInfo = base_cmds.GetModuleInfo;
};

pub const urcs = struct {
    pub const Creg = @import("../../at/urcs.zig").CregUrc;
};

pub const init_sequence = &[_]type{base_cmds.Probe};
