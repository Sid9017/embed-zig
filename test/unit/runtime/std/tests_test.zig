const std = @import("std");

test {
    _ = @import("time_test.zig");
    _ = @import("thread_test.zig");
    _ = @import("rng_test.zig");
    _ = @import("system_test.zig");
    _ = @import("fs_test.zig");
    _ = @import("socket_test.zig");
    _ = @import("ota_backend_test.zig");
    _ = @import("channel_test.zig");
}
