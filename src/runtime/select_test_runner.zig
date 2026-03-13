//! Selector 行为一致性测试运行器
//!
//! 本文件接受一个 Selector 的实现（通过 comptime 参数传入），运行全部测试，
//! 验证其行为与 Go `select` 语义一致。
//!
//! 这里的"同方向"是指：一次调用只测 `recv` 选择，或者只测 `send` 选择；
//! 不要求像 Go 那样在同一个 `select` 语句里同时混合收发 case。
//!
//! 以下是完整的测试要点清单：
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  A. 基础语义
//! ═══════════════════════════════════════════════════════════
//!
//! Go 的 `select` 在没有任何 case 时永久阻塞，在只有 `default` 时立即返回。
//! 我们的 API 通过 `timeout_ms` 统一表达这三种模式：
//!   -1 = 永远等待（无 default、无 timer）
//!    0 = 立即返回（等价 Go `select { default: ... }`）
//!   >0 = 带超时（等价 Go `select { case ...: ... case <-time.After(d): ... }`）
//!
//! ── A1. 空 selector ──
//!
//!  1. 没有任何 channel 时，`recv(0)` 立即返回 `ok = false`，不阻塞不崩溃
//!  2. 没有任何 channel 时，`send(value, 0)` 立即返回 `ok = false`，不阻塞不崩溃
//!
//! ── A2. timeout 语义 ──
//!
//!  3. `timeout_ms = 0`：所有 channel 均无数据时，`recv` 立即返回 `ok = false`
//!  4. `timeout_ms = 0`：所有 channel 均已满时，`send` 立即返回 `ok = false`
//!  5. `timeout_ms > 0`：超时前无分支就绪，在超时点返回 `ok = false`，
//!     不会永久阻塞；等价于 Go `select` 里额外放入一个
//!     `time.Timer` / `time.After` 超时分支
//!  6. `timeout_ms > 0`：超时前有分支就绪，正常命中该分支并返回数据
//!  7. `timeout_ms = -1`：当存在未来可命中的分支时，阻塞等待直到有分支就绪
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  B. recv 选择
//! ═══════════════════════════════════════════════════════════
//!
//! 对齐 Go `select { case v := <-ch1: ... case v := <-ch2: ... }` 的语义。
//! 多个 case 同时 ready 时，Go 会伪随机选择其中一个。
//!
//! ── B1. 单分支命中 ──
//!
//!  8. 唯一可读 channel 有数据时，`recv` 命中该 channel，
//!     返回正确的 `index`、`value` 和 `ok = true`
//!  9. 多个 channel 中只有一个有数据，`recv` 只命中那个有数据的 channel
//!
//! ── B2. 多分支同时 ready ──
//!
//!  10. 多个 channel 同时有数据时，`recv` 结果必须来自其中之一，
//!      不能返回未 ready 的 channel
//!  11. 多个 channel 同时 ready 时的随机选择：重复多轮后，
//!      命中结果应覆盖多个 ready channel，不能总是固定偏向同一个分支
//!
//! ── B3. 部分 ready ──
//!
//!  12. 部分 ready、部分不 ready 时，只允许从当前 ready 的 channel 中选择，
//!      不能因为数组顺序而误选未 ready 分支
//!  13. ready 分支被消费后再次调用，上一次已消费的数据不能重复命中，
//!      后续选择要反映最新 channel 状态
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  C. send 选择
//! ═══════════════════════════════════════════════════════════
//!
//! 对齐 Go `select { case ch1 <- v: ... case ch2 <- v: ... }` 的语义。
//!
//! ── C1. 单分支命中 ──
//!
//!  14. 唯一可写 channel 有空位时，`send` 命中该 channel，
//!      返回正确的 `index` 和 `ok = true`
//!  15. 多个 channel 中只有一个有空位，`send` 只命中那个有空位的 channel
//!
//! ── C2. 多分支同时 ready ──
//!
//!  16. 多个 channel 同时有空位时，`send` 结果必须来自其中之一，
//!      不能写入到未 ready 的 channel
//!  17. 多个 channel 同时 ready 时的随机选择：重复多轮后，
//!      命中结果应覆盖多个 ready channel，不能总是固定偏向同一个分支
//!
//! ── C3. 部分 ready ──
//!
//!  18. 部分 ready、部分不 ready 时，只允许写入当前可写的 channel，
//!      不能因为数组顺序而误选不可写分支
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  D. close 与 recv select
//! ═══════════════════════════════════════════════════════════
//!
//! Go 中从已关闭 channel 接收会立即返回零值和 `ok = false`；
//! 但如果缓冲区仍有数据，会先读完再报告关闭。
//! 关闭的 channel 在 `select` 里被视为"立即可完成"的分支。
//!
//! ── D1. 缓冲数据排空 ──
//!
//!  19. channel 已 close 但缓冲区仍有数据时，`recv select` 仍应先读出剩余数据，
//!      `ok = true`，再在耗尽后表现为关闭完成
//!  20. 关闭且已耗尽的 channel 参与 `recv select`，命中该分支并返回 `ok = false`
//!
//! ── D2. 关闭分支的立即命中 ──
//!
//!  21. 单个已关闭且耗尽的 channel 参与 `recv select`，
//!      应能立即被选中，而不是阻塞
//!  22. 多个已关闭且耗尽的 channel 同时参与 `recv select`，
//!      应从这些可立即完成的分支中随机选择一个
//!
//! ── D3. 关闭与正常分支混合 ──
//!
//!  23. 关闭 channel 与正常可读 channel 同时参与 `recv select`，
//!      结果必须只落在"立即可完成"的分支集合里，
//!      并允许随机选择其中任一项
//!  24. 所有 channel 都关闭且耗尽时，`recv select` 应稳定落在
//!      "立即可完成"的关闭分支上，并返回 `ok = false`
//!
//! ── D4. close 唤醒阻塞中的 recv select ──
//!
//!  25. `recv` 正在 `timeout_ms = -1` 等待时，相关 channel 被 close，
//!      等待方应被唤醒并得到 `ok = false`
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  E. close 与 send select
//! ═══════════════════════════════════════════════════════════
//!
//! Go 中向已关闭 channel 发送会 panic。
//! 我们的 API 不暴露 panic 语义，但必须保证：
//! 发送不能成功、结果稳定、可检测、绝不偷偷写入。
//!
//! ── E1. 单个关闭 channel 写入 ──
//!
//!  26. 向已关闭 channel 发送绝不能被报告为成功，
//!      若被命中也必须返回 `ok = false`
//!  27. close 之后再 send 不能把值写进去，
//!      后续 `recv` 也不能读到这次非法写入的数据
//!
//! ── E2. 多个关闭 channel 写入 ──
//!
//!  28. 多个已关闭 channel 同时参与 `send select` 时，
//!      不能出现伪成功、脏写入、死循环或卡死
//!
//! ── E3. 关闭与未关闭混合写入 ──
//!
//!  29. 若同时存在可写的打开 channel 与不可写的关闭 channel，
//!      `send select` 只能成功写到打开且 ready 的分支
//!  30. 所有 channel 都关闭时，`send select` 应稳定返回失败，
//!      不能阻塞，不能随机报告成功
//!
//! ── E4. close 唤醒阻塞中的 send select ──
//!
//!  31. `send` 正在 `timeout_ms = -1` 等待时，相关 channel 被 close，
//!      等待方应被唤醒并得到 `ok = false`
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  F. close 幂等性
//! ═══════════════════════════════════════════════════════════
//!
//!  32. 重复 close 不应制造额外事件、重复成功、虚假 ready
//!      或破坏随机选择集合
//!  33. 多次 close 后 `recv select` 行为与单次 close 后一致
//!  34. 多次 close 后 `send select` 行为与单次 close 后一致
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  G. 一致性与稳定性
//! ═══════════════════════════════════════════════════════════
//!
//! ── G1. 索引与结果正确性 ──
//!
//!  35. 返回的 `index` 必须对应传入 selector 时的 channel 顺序，
//!      而不是内部重排后的顺序
//!  36. 凡是返回 `ok = true` 的分支，后续检查必须能证明
//!      数据确实被接收或发送成功
//!
//! ── G2. 副作用隔离 ──
//!
//!  37. 一次 `select` 只能消费或写入被选中的那个 channel，
//!      其余分支状态保持不变
//!
//! ── G3. 高频与压力 ──
//!
//!  38. 在大量循环 `recv select` / `send select` 中不能出现
//!      饥饿、明显偏置、死锁或资源泄漏迹象
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  语义映射说明
//! ═══════════════════════════════════════════════════════════
//!
//! - `recv select` 对齐 Go `v, ok := <-ch` 的判定语义：
//!   这里没有零值返回约束，重点是 `ok` 与被选中的 `index` 必须正确。
//! - 对"关闭 channel 的接收"采用 Go 风格理解：
//!   关闭不会抹掉已缓冲的数据；缓冲读尽后，接收应立即完成并给出失败态。
//! - 对"关闭 channel 的发送"采用 Go 风格理解：
//!   发送不能成功；当前 API 不暴露 panic 语义，
//!   但至少要保证结果稳定、可检测、绝不偷偷写入。
//! - 对"多个 case 同时 ready"采用 Go 风格理解：
//!   可以任选其一，但必须只从 ready 集合中选，
//!   且应具备近似随机性，而不是顺序优先。
//! - 对"default 语义"统一映射到 `timeout_ms = 0`。
//! - 对"超时 case 语义"统一映射到 `timeout_ms > 0`，
//!   可理解为隐含加入了一个 `time.Timer` / `time.After` 分支。
//! - 对"阻塞等待直到可继续"统一映射到 `timeout_ms = -1`。
//!
//! 用法示例：
//! ```
//! const Runner = @import("select_test_runner.zig").SelectTestRunner(MySelector, MyChannel);
//!
//! test { try Runner.run(std.testing.allocator, .{ .concurrency = false }); }        // 只跑基础
//! test { try Runner.run(std.testing.allocator, .{ .basic = false }); }              // 只跑并发
//! ```

const std = @import("std");
const testing = std.testing;

pub fn SelectTestRunner(comptime Sel: type, comptime Ch: type) type {
    const Event = Ch.event_t;

    return struct {
        pub const Options = struct {
            basic: bool = false,
            concurrency: bool = false,
        };

        pub fn run(allocator: std.mem.Allocator, opts: Options) !void {
            var passed: u32 = 0;
            var failed: u32 = 0;
            const run_start = std.time.nanoTimestamp();

            if (opts.basic) {
                runOne("emptyRecv", allocator, &passed, &failed, testEmptyRecv);
                runOne("emptySend", allocator, &passed, &failed, testEmptySend);
                runOne("timeoutZeroRecvNoData", allocator, &passed, &failed, testTimeoutZeroRecvNoData);
                runOne("timeoutZeroSendAllFull", allocator, &passed, &failed, testTimeoutZeroSendAllFull);
                runOne("timeoutPositiveReadyBeforeExpiry", allocator, &passed, &failed, testTimeoutPositiveReadyBeforeExpiry);

                runOne("recvSingleHit", allocator, &passed, &failed, testRecvSingleHit);
                runOne("recvOnlyReadyHit", allocator, &passed, &failed, testRecvOnlyReadyHit);
                runOne("recvMultiReady", allocator, &passed, &failed, testRecvMultiReady);
                runOne("recvPartialReady", allocator, &passed, &failed, testRecvPartialReady);
                runOne("recvConsumedNotRepeated", allocator, &passed, &failed, testRecvConsumedNotRepeated);

                runOne("sendSingleHit", allocator, &passed, &failed, testSendSingleHit);
                runOne("sendOnlyReadyHit", allocator, &passed, &failed, testSendOnlyReadyHit);
                runOne("sendMultiReady", allocator, &passed, &failed, testSendMultiReady);
                runOne("sendPartialReady", allocator, &passed, &failed, testSendPartialReady);

                runOne("closeFlushThenClosed", allocator, &passed, &failed, testCloseFlushThenClosed);
                runOne("closedEmptyRecv", allocator, &passed, &failed, testClosedEmptyRecv);
                runOne("closedMixedWithReady", allocator, &passed, &failed, testClosedMixedWithReady);
                runOne("allClosedRecv", allocator, &passed, &failed, testAllClosedRecv);

                runOne("sendToClosedFails", allocator, &passed, &failed, testSendToClosedFails);
                runOne("sendToClosedNoWrite", allocator, &passed, &failed, testSendToClosedNoWrite);
                runOne("multiClosedSendNoHang", allocator, &passed, &failed, testMultiClosedSendNoHang);
                runOne("sendClosedMixedOpen", allocator, &passed, &failed, testSendClosedMixedOpen);
                runOne("allClosedSendFails", allocator, &passed, &failed, testAllClosedSendFails);

                runOne("doubleCloseNoExtraEvent", allocator, &passed, &failed, testDoubleCloseNoExtraEvent);
                runOne("doubleCloseRecvConsistent", allocator, &passed, &failed, testDoubleCloseRecvConsistent);
                runOne("doubleCloseSendConsistent", allocator, &passed, &failed, testDoubleCloseSendConsistent);

                runOne("indexMatchesOrder", allocator, &passed, &failed, testIndexMatchesOrder);
                runOne("okMeansDataMoved", allocator, &passed, &failed, testOkMeansDataMoved);
                runOne("noSideEffectOnOthers", allocator, &passed, &failed, testNoSideEffectOnOthers);
            }

            if (opts.concurrency) {
                runOne("timeoutPositiveExpires", allocator, &passed, &failed, testTimeoutPositiveExpires);
                runOne("timeoutBlockingRecv", allocator, &passed, &failed, testTimeoutBlockingRecv);

                runOne("recvMultiReadyFairness", allocator, &passed, &failed, testRecvMultiReadyFairness);

                runOne("sendMultiReadyFairness", allocator, &passed, &failed, testSendMultiReadyFairness);

                runOne("closedImmediateHit", allocator, &passed, &failed, testClosedImmediateHit);
                runOne("multiClosedRecvFairness", allocator, &passed, &failed, testMultiClosedRecvFairness);
                runOne("closeWakesBlockingRecv", allocator, &passed, &failed, testCloseWakesBlockingRecv);

                runOne("closeWakesBlockingSend", allocator, &passed, &failed, testCloseWakesBlockingSend);

                runOne("highFrequencyNoBias", allocator, &passed, &failed, testHighFrequencyNoBias);
            }

            const total_ns = std.time.nanoTimestamp() - run_start;
            const total_ms = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0;
            std.debug.print("\n── select: {d} passed, {d} failed, total {d:.1}ms ──\n", .{ passed, failed, total_ms });

            if (failed > 0) return error.TestsFailed;
        }

        fn runOne(
            comptime name: []const u8,
            allocator: std.mem.Allocator,
            passed: *u32,
            failed: *u32,
            comptime func: fn (std.mem.Allocator) anyerror!void,
        ) void {
            const start = std.time.nanoTimestamp();
            if (func(allocator)) |_| {
                const ns = std.time.nanoTimestamp() - start;
                const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
                std.debug.print("  PASS  {s} ({d:.1}ms)\n", .{ name, ms });
                passed.* += 1;
            } else |err| {
                const ns = std.time.nanoTimestamp() - start;
                const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
                std.debug.print("  FAIL  {s} ({d:.1}ms) — {s}\n", .{ name, ms, @errorName(err) });
                failed.* += 1;
            }
        }

        // ═══════════════════════════════════════════════════════════
        //  A. 基础语义 (#1-#7)
        // ═══════════════════════════════════════════════════════════

        fn testEmptyRecv(allocator: std.mem.Allocator) !void {
            const channels: []const Ch = &.{};
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const r = try sel.recv(0);
            try testing.expect(!r.ok);
        }

        fn testEmptySend(allocator: std.mem.Allocator) !void {
            const channels: []const Ch = &.{};
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const s = try sel.send(42, 0);
            try testing.expect(!s.ok);
        }

        fn testTimeoutZeroRecvNoData(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            const channels: []const Ch = &.{ch};
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const r = try sel.recv(0);
            try testing.expect(!r.ok);
        }

        fn testTimeoutZeroSendAllFull(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 1);
            defer ch.deinit();
            _ = try ch.send(99);

            const channels: []const Ch = &.{ch};
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const s = try sel.send(1, 0);
            try testing.expect(!s.ok);
        }

        fn testTimeoutPositiveExpires(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            const channels: []const Ch = &.{ch};
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const start = std.time.milliTimestamp();
            const r = try sel.recv(50);
            const elapsed = std.time.milliTimestamp() - start;

            try testing.expect(!r.ok);
            try testing.expect(elapsed >= 30);
        }

        fn testTimeoutPositiveReadyBeforeExpiry(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();
            _ = try ch.send(0xAA);

            const channels: []const Ch = &.{ch};
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const r = try sel.recv(5000);
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 0xAA), r.value);
            try testing.expectEqual(@as(usize, 0), r.index);
        }

        fn testTimeoutBlockingRecv(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            const channels: []const Ch = &.{ch};
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const t = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch) void {
                    std.Thread.sleep(30 * std.time.ns_per_ms);
                    _ = c.send(0xBB) catch {};
                }
            }.run, .{&ch});

            const r = try sel.recv(-1);
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 0xBB), r.value);
            t.join();
        }

        // ═══════════════════════════════════════════════════════════
        //  B. recv 选择 (#8-#13)
        // ═══════════════════════════════════════════════════════════

        fn testRecvSingleHit(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();
            _ = try ch.send(42);

            const channels: []const Ch = &.{ch};
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const r = try sel.recv(0);
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 42), r.value);
            try testing.expectEqual(@as(usize, 0), r.index);
        }

        fn testRecvOnlyReadyHit(allocator: std.mem.Allocator) !void {
            var ch0 = try Ch.init(allocator, 4);
            defer ch0.deinit();
            var ch1 = try Ch.init(allocator, 4);
            defer ch1.deinit();
            var ch2 = try Ch.init(allocator, 4);
            defer ch2.deinit();

            _ = try ch1.send(77);

            const channels: []const Ch = &.{ ch0, ch1, ch2 };
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const r = try sel.recv(0);
            try testing.expect(r.ok);
            try testing.expectEqual(@as(usize, 1), r.index);
            try testing.expectEqual(@as(Event, 77), r.value);
        }

        fn testRecvMultiReady(allocator: std.mem.Allocator) !void {
            var ch0 = try Ch.init(allocator, 4);
            defer ch0.deinit();
            var ch1 = try Ch.init(allocator, 4);
            defer ch1.deinit();

            _ = try ch0.send(10);
            _ = try ch1.send(20);

            const channels: []const Ch = &.{ ch0, ch1 };
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const r = try sel.recv(0);
            try testing.expect(r.ok);
            try testing.expect(r.index == 0 or r.index == 1);
            if (r.index == 0) {
                try testing.expectEqual(@as(Event, 10), r.value);
            } else {
                try testing.expectEqual(@as(Event, 20), r.value);
            }
        }

        fn testRecvMultiReadyFairness(allocator: std.mem.Allocator) !void {
            var ch0 = try Ch.init(allocator, 64);
            defer ch0.deinit();
            var ch1 = try Ch.init(allocator, 64);
            defer ch1.deinit();

            var hits = [2]u32{ 0, 0 };
            const rounds = 200;

            for (0..rounds) |_| {
                _ = try ch0.send(1);
                _ = try ch1.send(2);

                const channels: []const Ch = &.{ ch0, ch1 };
                var sel = try Sel.init(allocator, channels);
                const r = try sel.recv(0);
                sel.deinit();

                try testing.expect(r.ok);
                hits[r.index] += 1;

                if (r.index == 0) {
                    _ = try ch1.recv();
                } else {
                    _ = try ch0.recv();
                }
            }

            try testing.expect(hits[0] > 10);
            try testing.expect(hits[1] > 10);
        }

        fn testRecvPartialReady(allocator: std.mem.Allocator) !void {
            var ch0 = try Ch.init(allocator, 4);
            defer ch0.deinit();
            var ch1 = try Ch.init(allocator, 4);
            defer ch1.deinit();
            var ch2 = try Ch.init(allocator, 4);
            defer ch2.deinit();

            _ = try ch0.send(0xA);
            _ = try ch2.send(0xC);

            const channels: []const Ch = &.{ ch0, ch1, ch2 };
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const r = try sel.recv(0);
            try testing.expect(r.ok);
            try testing.expect(r.index == 0 or r.index == 2);
            try testing.expect(r.index != 1);
        }

        fn testRecvConsumedNotRepeated(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();
            _ = try ch.send(1);

            {
                const channels: []const Ch = &.{ch};
                var sel = try Sel.init(allocator, channels);
                const r = try sel.recv(0);
                sel.deinit();
                try testing.expect(r.ok);
                try testing.expectEqual(@as(Event, 1), r.value);
            }

            {
                const channels: []const Ch = &.{ch};
                var sel = try Sel.init(allocator, channels);
                const r = try sel.recv(0);
                sel.deinit();
                try testing.expect(!r.ok);
            }
        }

        // ═══════════════════════════════════════════════════════════
        //  C. send 选择 (#14-#18)
        // ═══════════════════════════════════════════════════════════

        fn testSendSingleHit(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            const channels: []const Ch = &.{ch};
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const s = try sel.send(55, 0);
            try testing.expect(s.ok);
            try testing.expectEqual(@as(usize, 0), s.index);

            const r = try ch.recv();
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 55), r.value);
        }

        fn testSendOnlyReadyHit(allocator: std.mem.Allocator) !void {
            var ch0 = try Ch.init(allocator, 1);
            defer ch0.deinit();
            var ch1 = try Ch.init(allocator, 1);
            defer ch1.deinit();

            _ = try ch0.send(99);

            const channels: []const Ch = &.{ ch0, ch1 };
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const s = try sel.send(88, 0);
            try testing.expect(s.ok);
            try testing.expectEqual(@as(usize, 1), s.index);
        }

        fn testSendMultiReady(allocator: std.mem.Allocator) !void {
            var ch0 = try Ch.init(allocator, 4);
            defer ch0.deinit();
            var ch1 = try Ch.init(allocator, 4);
            defer ch1.deinit();

            const channels: []const Ch = &.{ ch0, ch1 };
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const s = try sel.send(33, 0);
            try testing.expect(s.ok);
            try testing.expect(s.index == 0 or s.index == 1);
        }

        fn testSendMultiReadyFairness(allocator: std.mem.Allocator) !void {
            var ch0 = try Ch.init(allocator, 256);
            defer ch0.deinit();
            var ch1 = try Ch.init(allocator, 256);
            defer ch1.deinit();

            var hits = [2]u32{ 0, 0 };
            const rounds = 200;

            for (0..rounds) |_| {
                const channels: []const Ch = &.{ ch0, ch1 };
                var sel = try Sel.init(allocator, channels);
                const s = try sel.send(1, 0);
                sel.deinit();

                try testing.expect(s.ok);
                hits[s.index] += 1;
            }

            for (0..rounds) |_| {
                _ = ch0.tryRecv();
                _ = ch1.tryRecv();
            }

            try testing.expect(hits[0] > 10);
            try testing.expect(hits[1] > 10);
        }

        fn testSendPartialReady(allocator: std.mem.Allocator) !void {
            var ch0 = try Ch.init(allocator, 1);
            defer ch0.deinit();
            var ch1 = try Ch.init(allocator, 1);
            defer ch1.deinit();
            var ch2 = try Ch.init(allocator, 1);
            defer ch2.deinit();

            _ = try ch0.send(0);
            _ = try ch2.send(0);

            const channels: []const Ch = &.{ ch0, ch1, ch2 };
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const s = try sel.send(7, 0);
            try testing.expect(s.ok);
            try testing.expectEqual(@as(usize, 1), s.index);
        }

        // ═══════════════════════════════════════════════════════════
        //  D. close 与 recv select (#19-#25)
        // ═══════════════════════════════════════════════════════════

        fn testCloseFlushThenClosed(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 8);
            defer ch.deinit();
            _ = try ch.send(10);
            _ = try ch.send(20);
            ch.close();

            const channels: []const Ch = &.{ch};

            {
                var sel = try Sel.init(allocator, channels);
                const r = try sel.recv(0);
                sel.deinit();
                try testing.expect(r.ok);
                try testing.expectEqual(@as(Event, 10), r.value);
            }
            {
                var sel = try Sel.init(allocator, channels);
                const r = try sel.recv(0);
                sel.deinit();
                try testing.expect(r.ok);
                try testing.expectEqual(@as(Event, 20), r.value);
            }
            {
                var sel = try Sel.init(allocator, channels);
                const r = try sel.recv(0);
                sel.deinit();
                try testing.expect(!r.ok);
            }
        }

        fn testClosedEmptyRecv(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();
            ch.close();

            const channels: []const Ch = &.{ch};
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const r = try sel.recv(0);
            try testing.expect(!r.ok);
        }

        fn testClosedImmediateHit(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();
            ch.close();

            const channels: []const Ch = &.{ch};
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const start = std.time.milliTimestamp();
            const r = try sel.recv(5000);
            const elapsed = std.time.milliTimestamp() - start;

            try testing.expect(!r.ok);
            try testing.expect(elapsed < 1000);
        }

        fn testMultiClosedRecvFairness(allocator: std.mem.Allocator) !void {
            var ch0 = try Ch.init(allocator, 4);
            defer ch0.deinit();
            var ch1 = try Ch.init(allocator, 4);
            defer ch1.deinit();
            ch0.close();
            ch1.close();

            var hits = [2]u32{ 0, 0 };
            for (0..100) |_| {
                const channels: []const Ch = &.{ ch0, ch1 };
                var sel = try Sel.init(allocator, channels);
                const r = try sel.recv(0);
                sel.deinit();
                if (r.index < 2) hits[r.index] += 1;
            }

            try testing.expect(hits[0] > 0);
            try testing.expect(hits[1] > 0);
        }

        fn testClosedMixedWithReady(allocator: std.mem.Allocator) !void {
            var ch_closed = try Ch.init(allocator, 4);
            defer ch_closed.deinit();
            ch_closed.close();

            var ch_data = try Ch.init(allocator, 4);
            defer ch_data.deinit();
            _ = try ch_data.send(0xDD);

            const channels: []const Ch = &.{ ch_closed, ch_data };
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const r = try sel.recv(0);
            try testing.expect(r.index == 0 or r.index == 1);
        }

        fn testAllClosedRecv(allocator: std.mem.Allocator) !void {
            var ch0 = try Ch.init(allocator, 4);
            defer ch0.deinit();
            var ch1 = try Ch.init(allocator, 4);
            defer ch1.deinit();
            ch0.close();
            ch1.close();

            const channels: []const Ch = &.{ ch0, ch1 };
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            for (0..10) |_| {
                const r = try sel.recv(0);
                try testing.expect(!r.ok);
            }
        }

        fn testCloseWakesBlockingRecv(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            const channels: []const Ch = &.{ch};
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            var recv_ok = std.atomic.Value(bool).init(true);
            const t = try std.Thread.spawn(.{}, struct {
                fn run(s: *Sel, flag: *std.atomic.Value(bool)) void {
                    const r = s.recv(-1) catch {
                        flag.store(false, .release);
                        return;
                    };
                    flag.store(r.ok, .release);
                }
            }.run, .{ &sel, &recv_ok });

            std.Thread.sleep(50 * std.time.ns_per_ms);
            ch.close();
            t.join();

            try testing.expect(!recv_ok.load(.acquire));
        }

        // ═══════════════════════════════════════════════════════════
        //  E. close 与 send select (#26-#31)
        // ═══════════════════════════════════════════════════════════

        fn testSendToClosedFails(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();
            ch.close();

            const channels: []const Ch = &.{ch};
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const s = try sel.send(1, 0);
            try testing.expect(!s.ok);
        }

        fn testSendToClosedNoWrite(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();
            ch.close();

            {
                const channels: []const Ch = &.{ch};
                var sel = try Sel.init(allocator, channels);
                _ = try sel.send(0xFF, 0);
                sel.deinit();
            }

            const r = try ch.recv();
            try testing.expect(!r.ok);
        }

        fn testMultiClosedSendNoHang(allocator: std.mem.Allocator) !void {
            var ch0 = try Ch.init(allocator, 4);
            defer ch0.deinit();
            var ch1 = try Ch.init(allocator, 4);
            defer ch1.deinit();
            ch0.close();
            ch1.close();

            const channels: []const Ch = &.{ ch0, ch1 };
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            for (0..10) |_| {
                const s = try sel.send(1, 0);
                try testing.expect(!s.ok);
            }
        }

        fn testSendClosedMixedOpen(allocator: std.mem.Allocator) !void {
            var ch_closed = try Ch.init(allocator, 4);
            defer ch_closed.deinit();
            ch_closed.close();

            var ch_open = try Ch.init(allocator, 4);
            defer ch_open.deinit();

            const channels: []const Ch = &.{ ch_closed, ch_open };
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const s = try sel.send(42, 0);
            try testing.expect(s.ok);
            try testing.expectEqual(@as(usize, 1), s.index);

            const r = try ch_open.recv();
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 42), r.value);
        }

        fn testAllClosedSendFails(allocator: std.mem.Allocator) !void {
            var ch0 = try Ch.init(allocator, 4);
            defer ch0.deinit();
            var ch1 = try Ch.init(allocator, 4);
            defer ch1.deinit();
            ch0.close();
            ch1.close();

            const channels: []const Ch = &.{ ch0, ch1 };
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const s = try sel.send(1, 0);
            try testing.expect(!s.ok);
        }

        fn testCloseWakesBlockingSend(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 1);
            defer ch.deinit();
            _ = try ch.send(0);

            const channels: []const Ch = &.{ch};
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            var send_ok = std.atomic.Value(bool).init(true);
            const t = try std.Thread.spawn(.{}, struct {
                fn run(s: *Sel, flag: *std.atomic.Value(bool)) void {
                    const sr = s.send(1, -1) catch {
                        flag.store(false, .release);
                        return;
                    };
                    flag.store(sr.ok, .release);
                }
            }.run, .{ &sel, &send_ok });

            std.Thread.sleep(50 * std.time.ns_per_ms);
            ch.close();
            t.join();

            try testing.expect(!send_ok.load(.acquire));
        }

        // ═══════════════════════════════════════════════════════════
        //  F. close 幂等性 (#32-#34)
        // ═══════════════════════════════════════════════════════════

        fn testDoubleCloseNoExtraEvent(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();
            ch.close();
            ch.close();

            const channels: []const Ch = &.{ch};
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const r = try sel.recv(0);
            try testing.expect(!r.ok);
        }

        fn testDoubleCloseRecvConsistent(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();
            _ = try ch.send(5);
            ch.close();
            ch.close();

            const channels: []const Ch = &.{ch};

            {
                var sel = try Sel.init(allocator, channels);
                const r = try sel.recv(0);
                sel.deinit();
                try testing.expect(r.ok);
                try testing.expectEqual(@as(Event, 5), r.value);
            }
            {
                var sel = try Sel.init(allocator, channels);
                const r = try sel.recv(0);
                sel.deinit();
                try testing.expect(!r.ok);
            }
        }

        fn testDoubleCloseSendConsistent(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();
            ch.close();
            ch.close();

            const channels: []const Ch = &.{ch};
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const s = try sel.send(1, 0);
            try testing.expect(!s.ok);
        }

        // ═══════════════════════════════════════════════════════════
        //  G. 一致性与稳定性 (#35-#38)
        // ═══════════════════════════════════════════════════════════

        fn testIndexMatchesOrder(allocator: std.mem.Allocator) !void {
            var ch0 = try Ch.init(allocator, 4);
            defer ch0.deinit();
            var ch1 = try Ch.init(allocator, 4);
            defer ch1.deinit();
            var ch2 = try Ch.init(allocator, 4);
            defer ch2.deinit();

            _ = try ch0.send(100);
            _ = try ch1.send(200);
            _ = try ch2.send(300);

            const channels: []const Ch = &.{ ch0, ch1, ch2 };
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const r = try sel.recv(0);
            try testing.expect(r.ok);
            const expected_val: Event = switch (r.index) {
                0 => 100,
                1 => 200,
                2 => 300,
                else => unreachable,
            };
            try testing.expectEqual(expected_val, r.value);
        }

        fn testOkMeansDataMoved(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            const channels: []const Ch = &.{ch};
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const s = try sel.send(0xFACE, 0);
            try testing.expect(s.ok);

            const r = try ch.recv();
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 0xFACE), r.value);
        }

        fn testNoSideEffectOnOthers(allocator: std.mem.Allocator) !void {
            var ch0 = try Ch.init(allocator, 4);
            defer ch0.deinit();
            var ch1 = try Ch.init(allocator, 4);
            defer ch1.deinit();

            _ = try ch0.send(0xAA);
            _ = try ch1.send(0xBB);

            const channels: []const Ch = &.{ ch0, ch1 };
            var sel = try Sel.init(allocator, channels);
            defer sel.deinit();

            const r = try sel.recv(0);
            try testing.expect(r.ok);

            const other_idx: usize = if (r.index == 0) 1 else 0;
            var other_ch = channels[other_idx];
            const other_r = try other_ch.recv();
            try testing.expect(other_r.ok);
        }

        fn testHighFrequencyNoBias(allocator: std.mem.Allocator) !void {
            const N = 3;
            var chs: [N]Ch = undefined;
            for (0..N) |i| {
                chs[i] = try Ch.init(allocator, 64);
            }
            defer for (0..N) |i| {
                chs[i].deinit();
            };

            var hits = [_]u32{0} ** N;
            const rounds = 600;

            for (0..rounds) |_| {
                for (0..N) |i| {
                    _ = try chs[i].send(1);
                }

                const channels: []const Ch = &chs;
                var sel = try Sel.init(allocator, channels);
                const r = try sel.recv(0);
                sel.deinit();

                try testing.expect(r.ok);
                hits[r.index] += 1;

                for (0..N) |i| {
                    _ = chs[i].tryRecv();
                }
            }

            for (0..N) |i| {
                try testing.expect(hits[i] > 20);
            }
        }
    };
}
