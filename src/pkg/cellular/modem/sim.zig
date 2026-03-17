//! SIM card management: status, IMSI, ICCID via AtEngine. Full implementation in Step 5.
//! See plan.md §5.8.

const types = @import("../types.zig");

/// SIM operations backed by an AT engine. Implement getStatus/getImsi/getIccid in Step 5.
pub fn Sim(comptime Time: type) type {
    comptime {
        _ = Time;
    }
    return struct {
        pub fn init() @This() {
            return .{};
        }

        pub fn getStatus(self: *@This(), at: anytype) !types.SimStatus {
            _ = self;
            _ = at;
            return .not_inserted;
        }

        pub fn getImsi(self: *@This(), at: anytype) ![]const u8 {
            _ = self;
            _ = at;
            return "";
        }

        pub fn getIccid(self: *@This(), at: anytype) ![]const u8 {
            _ = self;
            _ = at;
            return "";
        }
    };
}
