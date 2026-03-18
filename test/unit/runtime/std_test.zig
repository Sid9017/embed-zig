const std = @import("std");
const embed = @import("embed");
const Std = embed.runtime.std;

test "std implementations satisfy all runtime contracts" {
    _ = embed.runtime.is(Std);
}

test {
    _ = @import("std/tests_test.zig");
}
