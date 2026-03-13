const std = @import("std");
const root = @import("mod.zig");

test {
    std.testing.refAllDecls(root);
    _ = @import("runtime/std.zig");
    _ = @import("pkg/audio/engine.zig");
    _ = @import("pkg/audio/mixer.zig");
    _ = @import("pkg/audio/override_buffer.zig");
    _ = @import("pkg/audio/resampler.zig");
    _ = @import("pkg/event/bus_integration_test.zig");
    _ = @import("pkg/net/tls/stress_test.zig");
    _ = @import("pkg/net/ws/e2e_test.zig");
    _ = @import("pkg/ble/xfer/xfer_test.zig");
    _ = @import("pkg/ble/term/term_test.zig");
    _ = @import("pkg/ble/ble_test.zig");
    _ = @import("pkg/ui/render/framebuffer/dirty.zig");
    _ = @import("pkg/ui/render/framebuffer/framebuffer.zig");
    _ = @import("pkg/ui/render/framebuffer/font.zig");
    _ = @import("pkg/ui/render/framebuffer/image.zig");
    _ = @import("pkg/ui/render/framebuffer/anim.zig");
    _ = @import("pkg/ui/render/framebuffer/scene.zig");
    _ = @import("pkg/ui/render/font/api.zig");
    _ = @import("pkg/ui/led_strip/frame.zig");
    _ = @import("pkg/ui/led_strip/transition.zig");
    _ = @import("pkg/ui/led_strip/animator.zig");
    _ = @import("pkg/flux/store.zig");
    _ = @import("pkg/flux/app_state_manager.zig");
    _ = @import("pkg/app/app_runtime.zig");
}
