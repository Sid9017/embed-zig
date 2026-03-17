//! Signal quality monitoring via AtEngine (e.g. AT+CSQ). Full implementation in Step 6.
//! See plan.md §5.9.

const types = @import("../types.zig");

/// Signal operations backed by an AT engine. Implement getStrength in Step 6.
pub fn Signal(comptime Time: type) type {
    comptime {
        _ = Time;
    }
    return struct {
        pub fn init() @This() {
            return .{};
        }

        pub fn getStrength(self: *@This(), at: anytype) !types.CellularSignalInfo {
            _ = self;
            _ = at;
            return .{ .rssi = -113 };
        }
    };
}
