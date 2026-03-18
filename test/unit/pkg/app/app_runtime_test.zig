const std = @import("std");
const embed = @import("embed");
const app = embed.pkg.app;

const testing = std.testing;
const Std = embed.runtime.std;

const TestApp = struct {
    pub const State = struct {
        count: u32 = 0,
    };

    pub const InputSpec = .{
        .increment = void,
    };

    pub const OutputSpec = .{
        .doubled = u32,
    };

    const BusType = embed.pkg.event.Bus(InputSpec, OutputSpec, Std);

    pub fn reduce(state: *State, ev: BusType.BusEvent) void {
        switch (ev) {
            .input => |input| switch (input) {
                .increment => state.count += 1,
                .tick => {},
            },
            .doubled => |v| state.count += v,
        }
    }
};

const TestRuntime = app.AppRuntime(TestApp, Std);

test "AppRuntime: inject dispatches through bus to reducer" {
    var rt = try TestRuntime.init(testing.allocator, 16, .{});
    defer rt.deinit();

    const t = try std.Thread.spawn(.{}, struct {
        fn run(bus: *@TypeOf(rt.bus)) void {
            bus.run();
        }
    }.run, .{&rt.bus});

    _ = try rt.inject(.increment, {});

    const r = try rt.recv();
    try testing.expect(r.ok);
    rt.dispatch(r.value);

    try testing.expectEqual(@as(u32, 1), rt.getState().count);
    try testing.expect(rt.isDirty());

    rt.commitFrame();
    try testing.expect(!rt.isDirty());

    rt.bus.stop();
    t.join();
}

test "AppRuntime: commitFrame resets dirty" {
    var rt = try TestRuntime.init(testing.allocator, 16, .{});
    defer rt.deinit();

    const t = try std.Thread.spawn(.{}, struct {
        fn run(bus: *@TypeOf(rt.bus)) void {
            bus.run();
        }
    }.run, .{&rt.bus});

    _ = try rt.inject(.increment, {});
    const r1 = try rt.recv();
    try testing.expect(r1.ok);
    rt.dispatch(r1.value);

    try testing.expect(rt.isDirty());
    try testing.expectEqual(@as(u32, 1), rt.getState().count);

    rt.commitFrame();
    try testing.expect(!rt.isDirty());

    _ = try rt.inject(.increment, {});
    const r2 = try rt.recv();
    try testing.expect(r2.ok);
    rt.dispatch(r2.value);

    try testing.expect(rt.isDirty());
    try testing.expectEqual(@as(u32, 2), rt.getState().count);

    rt.bus.stop();
    t.join();
}
