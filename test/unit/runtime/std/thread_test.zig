const std = @import("std");
const embed = @import("embed");
const Std = embed.runtime.std;
const Time = Std.Time;
const Mutex = Std.Mutex;
const Condition = Std.Condition;
const Notify = Std.Notify;
const Thread = Std.Thread;

const std_time: Time = .{};

fn markDone(ctx: ?*anyopaque) void {
    const value: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
    _ = value.fetchAdd(1, .seq_cst);
}

fn notifyAfterDelay(ctx: ?*anyopaque) void {
    const n: *Notify = @ptrCast(@alignCast(ctx.?));
    std_time.sleepMs(20);
    n.signal();
}

test "std thread spawn/join executes task" {
    var counter = std.atomic.Value(u32).init(0);
    var th = try Thread.spawn(.{}, markDone, @ptrCast(&counter));
    th.join();
    try std.testing.expectEqual(@as(u32, 1), counter.load(.seq_cst));
}

test "std condition wait/signal works" {
    const Ctx = struct {
        mutex: Mutex,
        cond: Condition,
        ready: bool,
    };

    const waiter = struct {
        fn run(ptr: ?*anyopaque) void {
            const ctx: *Ctx = @ptrCast(@alignCast(ptr.?));
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            while (!ctx.ready) {
                ctx.cond.wait(&ctx.mutex);
            }
        }
    };

    var ctx = Ctx{ .mutex = Mutex.init(), .cond = Condition.init(), .ready = false };
    defer ctx.cond.deinit();
    defer ctx.mutex.deinit();

    var th = try Thread.spawn(.{}, waiter.run, @ptrCast(&ctx));
    std_time.sleepMs(10);

    ctx.mutex.lock();
    ctx.ready = true;
    ctx.cond.signal();
    ctx.mutex.unlock();

    th.join();
    try std.testing.expect(ctx.ready);
}

test "std notify timedWait" {
    var notify = Notify.init();
    defer notify.deinit();

    var th = try Thread.spawn(.{}, notifyAfterDelay, @ptrCast(&notify));

    const early = notify.timedWait(5 * std.time.ns_per_ms);
    try std.testing.expect(!early);

    const later = notify.timedWait(300 * std.time.ns_per_ms);
    try std.testing.expect(later);

    th.join();
}
