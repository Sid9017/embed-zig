//! Mock "esp" module for running firmware tests from embed-zig root (no esp-zig).
//! Only provides .embed so that app.zig's @import("esp").embed works.

pub const embed = @import("embed");
