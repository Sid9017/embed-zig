const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const store_mod = embed.pkg.flux.store;

// ============================================================================
// Tests
// ============================================================================

const TestState = struct {
    count: u32 = 0,
    name: [8]u8 = .{0} ** 8,
};

const TestEvent = union(enum) {
    increment,
    decrement,
    reset,
    add: u32,
};

fn testReducer(state: *TestState, event: TestEvent) void {
    switch (event) {
        .increment => state.count += 1,
        .decrement => {
            if (state.count > 0) state.count -= 1;
        },
        .reset => state.* = .{},
        .add => |n| state.count += n,
    }
}

test "init sets dirty for first frame" {
    const store = store_mod.Store(TestState, TestEvent).init(.{}, testReducer);
    try testing.expect(store.isDirty());
    try testing.expectEqual(@as(u32, 0), store.getState().count);
}

test "dispatch modifies state and marks dirty" {
    var store = store_mod.Store(TestState, TestEvent).init(.{}, testReducer);
    store.commitFrame(); // clear initial dirty
    try testing.expect(!store.isDirty());

    store.dispatch(.increment);
    try testing.expect(store.isDirty());
    try testing.expectEqual(@as(u32, 1), store.getState().count);
}

test "commitFrame snapshots prev and clears dirty" {
    var store = store_mod.Store(TestState, TestEvent).init(.{}, testReducer);
    store.dispatch(.increment);
    store.dispatch(.increment);
    try testing.expectEqual(@as(u32, 2), store.getState().count);
    try testing.expectEqual(@as(u32, 0), store.getPrev().count);

    store.commitFrame();
    try testing.expect(!store.isDirty());
    try testing.expectEqual(@as(u32, 2), store.getPrev().count);
    try testing.expectEqual(@as(u32, 2), store.getState().count);
}

test "dispatchBatch applies multiple events" {
    var store = store_mod.Store(TestState, TestEvent).init(.{}, testReducer);
    store.commitFrame();

    const events = [_]TestEvent{ .increment, .increment, .{ .add = 10 }, .decrement };
    store.dispatchBatch(&events);

    try testing.expect(store.isDirty());
    // increment(+1) + increment(+1) + add(10) + decrement(-1) = 11
    try testing.expectEqual(@as(u32, 11), store.getState().count);
}

test "dispatchBatch with empty slice does not mark dirty" {
    var store = store_mod.Store(TestState, TestEvent).init(.{}, testReducer);
    store.commitFrame();

    store.dispatchBatch(&[_]TestEvent{});
    try testing.expect(!store.isDirty());
}

test "prev tracks across multiple frames" {
    var store = store_mod.Store(TestState, TestEvent).init(.{}, testReducer);

    // Frame 1: count goes 0 → 3
    store.dispatch(.{ .add = 3 });
    store.commitFrame();
    try testing.expectEqual(@as(u32, 3), store.getPrev().count);

    // Frame 2: count goes 3 → 5
    store.dispatch(.{ .add = 2 });
    try testing.expectEqual(@as(u32, 3), store.getPrev().count);
    try testing.expectEqual(@as(u32, 5), store.getState().count);
    store.commitFrame();
    try testing.expectEqual(@as(u32, 5), store.getPrev().count);
}

test "reset via dispatch" {
    var store = store_mod.Store(TestState, TestEvent).init(.{}, testReducer);
    store.dispatch(.{ .add = 100 });
    store.dispatch(.reset);
    try testing.expectEqual(@as(u32, 0), store.getState().count);
}
