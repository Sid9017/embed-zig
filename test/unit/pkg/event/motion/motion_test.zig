const std = @import("std");
const embed = @import("embed");
const motion = embed.pkg.event.motion;

test {
    _ = motion.motion_types;
    _ = motion.detector;
}
