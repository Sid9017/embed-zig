const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const app_state_manager = embed.pkg.flux.app_state_manager;

// ============================================================================
// Tests
// ============================================================================

const TestApp = struct {
    pub const State = struct {
        count: u32 = 0,
        page: enum { home, settings } = .home,
    };

    pub const Event = union(enum) {
        increment,
        decrement,
        navigate: enum { home, settings },
    };

    pub fn reduce(state: *State, event: Event) void {
        switch (event) {
            .increment => state.count += 1,
            .decrement => if (state.count > 0) {
                state.count -= 1;
            },
            .navigate => |page| state.page = switch (page) {
                .home => .home,
                .settings => .settings,
            },
        }
    }
};

test "AppStateManager: init and dispatch" {
    var app = app_state_manager.AppStateManager(TestApp).init(.{ .fps = 30 });

    try testing.expectEqual(@as(u32, 0), app.getState().count);
    try testing.expect(app.isDirty()); // first frame always dirty

    app.dispatch(.increment);
    try testing.expectEqual(@as(u32, 1), app.getState().count);
    try testing.expect(app.isDirty());
}

test "AppStateManager: shouldRender respects fps" {
    var app = app_state_manager.AppStateManager(TestApp).init(.{ .fps = 30 });

    // First frame: dirty + enough time → should render
    try testing.expect(app.shouldRender(33));
    app.commitFrame(33);
    try testing.expect(!app.isDirty());

    // Dispatch event → dirty
    app.dispatch(.increment);
    try testing.expect(app.isDirty());

    // Too soon (only 10ms since last render at 33, need 33ms gap)
    try testing.expect(!app.shouldRender(43));

    // Enough time passed (33 + 33 = 66)
    try testing.expect(app.shouldRender(66));
    app.commitFrame(66);
}

test "AppStateManager: fps=0 unlimited" {
    var app = app_state_manager.AppStateManager(TestApp).init(.{ .fps = 0 });
    app.dispatch(.increment);
    // Should always render when dirty
    try testing.expect(app.shouldRender(0));
    app.commitFrame(0);
    app.dispatch(.increment);
    try testing.expect(app.shouldRender(1)); // even 1ms later
}

test "AppStateManager: no render when not dirty" {
    var app = app_state_manager.AppStateManager(TestApp).init(.{ .fps = 30 });
    app.commitFrame(0); // clear initial dirty

    // No events → not dirty → no render
    try testing.expect(!app.shouldRender(100));
}

test "AppStateManager: batch dispatch" {
    var app = app_state_manager.AppStateManager(TestApp).init(.{ .fps = 30 });
    app.commitFrame(0);

    const events = [_]TestApp.Event{ .increment, .increment, .increment };
    app.dispatchBatch(&events);

    try testing.expectEqual(@as(u32, 3), app.getState().count);
    try testing.expect(app.isDirty());
}

test "AppStateManager: state navigation" {
    var app = app_state_manager.AppStateManager(TestApp).init(.{ .fps = 30 });

    app.dispatch(.{ .navigate = .settings });
    try testing.expectEqual(.settings, app.getState().page);

    app.dispatch(.{ .navigate = .home });
    try testing.expectEqual(.home, app.getState().page);
}
