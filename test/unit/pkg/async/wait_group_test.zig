const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const runtime = embed.runtime;
const waitgroup = embed.pkg.async.waitgroup;

test "waitgroup basic synchronization add=10 done=10" {
    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.add(10);
    try std.testing.expect(!wg.isDone());
    try std.testing.expectEqual(@as(usize, 10), wg.remaining());

    var i: usize = 0;
    while (i < 10) : (i += 1) try wg.done();
    try std.testing.expect(wg.isDone());
    try std.testing.expectEqual(@as(usize, 0), wg.remaining());
}

test "waitgroup underflow returns error" {
    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    try std.testing.expectError(error.Underflow, wg.done());
}

test "waitgroup done after add underflow" {
    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.add(2);
    try wg.done();
    try wg.done();
    try std.testing.expectError(error.Underflow, wg.done());
}

test "waitgroup onComplete callback fires when reaching zero" {
    const Ctx = struct {
        var fired: bool = false;
        fn cb(_: ?*anyopaque) void {
            fired = true;
        }
    };
    Ctx.fired = false;

    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.onComplete(Ctx.cb, null);
    wg.add(3);

    try wg.done();
    try std.testing.expect(!Ctx.fired);
    try wg.done();
    try std.testing.expect(!Ctx.fired);
    try wg.done();
    try std.testing.expect(Ctx.fired);
}

test "waitgroup onComplete does not fire if never reaches zero" {
    const Ctx = struct {
        var fired: bool = false;
        fn cb(_: ?*anyopaque) void {
            fired = true;
        }
    };
    Ctx.fired = false;

    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.onComplete(Ctx.cb, null);
    wg.add(5);
    try wg.done();
    try wg.done();
    try std.testing.expect(!Ctx.fired);
}

test "waitgroup reset clears state" {
    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.add(5);
    try wg.done();
    wg.reset();
    try std.testing.expect(wg.isDone());
    try std.testing.expectEqual(@as(usize, 0), wg.remaining());
}

test "waitgroup fresh instance isDone is true" {
    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    try std.testing.expect(wg.isDone());
    try std.testing.expectEqual(@as(usize, 0), wg.remaining());
}

test "waitgroup multiple add calls accumulate" {
    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.add(3);
    wg.add(2);
    wg.add(5);
    try std.testing.expectEqual(@as(usize, 10), wg.remaining());

    var i: usize = 0;
    while (i < 10) : (i += 1) try wg.done();
    try std.testing.expect(wg.isDone());
}

test "waitgroup onComplete callback receives context" {
    const Ctx = struct {
        result: usize,
    };
    const handler = struct {
        fn cb(raw: ?*anyopaque) void {
            const ctx: *Ctx = @ptrCast(@alignCast(raw orelse return));
            ctx.result = 99;
        }
    }.cb;

    var ctx = Ctx{ .result = 0 };
    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.onComplete(handler, &ctx);
    wg.add(1);
    try wg.done();
    try std.testing.expectEqual(@as(usize, 99), ctx.result);
}

test "waitgroup reset then reuse" {
    const Ctx = struct {
        var count: usize = 0;
        fn cb(_: ?*anyopaque) void {
            count += 1;
        }
    };
    Ctx.count = 0;

    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.onComplete(Ctx.cb, null);
    wg.add(1);
    try wg.done();
    try std.testing.expectEqual(@as(usize, 1), Ctx.count);

    wg.reset();
    wg.onComplete(Ctx.cb, null);
    wg.add(2);
    try wg.done();
    try wg.done();
    try std.testing.expectEqual(@as(usize, 2), Ctx.count);
}

test "waitgroup done on reset waitgroup returns underflow" {
    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.add(3);
    wg.reset();
    try std.testing.expectError(error.Underflow, wg.done());
}

test "waitgroup onComplete does not fire on intermediate done" {
    const Ctx = struct {
        var fired_at: ?usize = null;
        var call_seq: usize = 0;
        fn cb(_: ?*anyopaque) void {
            fired_at = call_seq;
        }
    };
    Ctx.fired_at = null;
    Ctx.call_seq = 0;

    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.onComplete(Ctx.cb, null);
    wg.add(3);

    try wg.done();
    Ctx.call_seq = 1;
    try std.testing.expect(Ctx.fired_at == null);

    try wg.done();
    Ctx.call_seq = 2;
    try std.testing.expect(Ctx.fired_at == null);

    try wg.done();
    try std.testing.expectEqual(@as(usize, 2), Ctx.fired_at.?);
}

test "waitgroup add zero keeps done state unchanged" {
    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();

    try std.testing.expect(wg.isDone());
    wg.add(0);
    try std.testing.expect(wg.isDone());
    try std.testing.expectEqual(@as(usize, 0), wg.remaining());
}

test "waitgroup wait on zero pending returns immediately" {
    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();

    wg.wait();
    try std.testing.expect(wg.isDone());
}

test "waitgroup latest callback overrides previous registration" {
    const Ctx = struct {
        var a: usize = 0;
        var b: usize = 0;
        fn cbA(_: ?*anyopaque) void {
            a += 1;
        }
        fn cbB(_: ?*anyopaque) void {
            b += 1;
        }
    };
    Ctx.a = 0;
    Ctx.b = 0;

    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.onComplete(Ctx.cbA, null);
    wg.onComplete(Ctx.cbB, null);
    wg.add(1);
    try wg.done();

    try std.testing.expectEqual(@as(usize, 0), Ctx.a);
    try std.testing.expectEqual(@as(usize, 1), Ctx.b);
}

test "waitgroup reset clears callback registration" {
    const Ctx = struct {
        var fired: usize = 0;
        fn cb(_: ?*anyopaque) void {
            fired += 1;
        }
    };
    Ctx.fired = 0;

    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.onComplete(Ctx.cb, null);
    wg.add(1);
    wg.reset();
    wg.add(1);
    try wg.done();

    try std.testing.expectEqual(@as(usize, 0), Ctx.fired);
}

test "waitgroup supports multiple completion cycles" {
    const Ctx = struct {
        var fired: usize = 0;
        fn cb(_: ?*anyopaque) void {
            fired += 1;
        }
    };
    Ctx.fired = 0;

    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.onComplete(Ctx.cb, null);

    wg.add(1);
    try wg.done();
    wg.add(2);
    try wg.done();
    try wg.done();

    try std.testing.expectEqual(@as(usize, 2), Ctx.fired);
    try std.testing.expect(wg.isDone());
}

test "waitgroup callback can be registered after first completion" {
    const Ctx = struct {
        var fired: usize = 0;
        fn cb(_: ?*anyopaque) void {
            fired += 1;
        }
    };
    Ctx.fired = 0;

    var wg = waitgroup.WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();

    wg.add(1);
    try wg.done();
    wg.onComplete(Ctx.cb, null);
    wg.add(1);
    try wg.done();

    try std.testing.expectEqual(@as(usize, 1), Ctx.fired);
}
