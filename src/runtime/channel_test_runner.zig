//! Channel 行为一致性测试运行器
//!
//! 本文件接受一个 Channel(T) 的实现（通过 comptime 参数传入），运行全部测试，
//! 验证其行为与 Go channel 语义一致。
//!
//! 注意：本 runner 只使用 channel contract 暴露的 API（init/deinit/send/recv/close），
//! 不依赖 trySend/tryRecv/readFd/writeFd 等 impl 特有方法。
//! 那些 impl 特有的行为（如 readiness/selector 可观测性）应在 impl 自己的测试中覆盖。
//!
//! 用法示例：
//! ```
//! const runner = @import("channel_test_runner.zig").ChannelTestRunner(MyChannel);
//! test { try runner.run(std.testing.allocator, .{}); }                  // 全部跑
//! test { try runner.run(std.testing.allocator, .{ .long_running = false }); } // 只跑快速
//! ```
//!
//! 以下是完整的测试要点清单：
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  〇、无缓冲 channel（capacity=0）— Go rendezvous 语义
//! ═══════════════════════════════════════════════════════════
//!
//!  U1. capacity=0 时允许创建 channel（unbuffered）
//!  U2. unbuffered send 阻塞直到有 receiver 取走
//!  U3. unbuffered recv 阻塞直到有 sender 提供
//!  U4. unbuffered 握手后值正确传递
//!  U5. unbuffered 多轮 send/recv 握手不死锁
//!  U6. unbuffered close 唤醒阻塞的 recv，返回 ok=false
//!  U7. unbuffered close 唤醒阻塞的 send，返回 ok=false
//!  U8. unbuffered close 后 send 返回 ok=false
//!  U9. unbuffered close 后 recv 返回 ok=false
//!  U10. unbuffered SPSC 并发不丢消息
//!  U11. unbuffered MPSC 并发不丢消息
//!  U12. unbuffered deinit 无泄漏
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  一、初始化与基本属性
//! ═══════════════════════════════════════════════════════════
//!
//!  1. capacity=1 时允许创建 channel（单槽位缓冲）
//!  2. capacity>1 时允许创建 channel（多槽位缓冲，如 64, 1024）
//!  3. 新建有缓冲 channel 的初始状态正确：
//!     send 后可 recv，值一致
//!  4. deinit 后资源释放干净（allocator 无泄漏）
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  二、发送与接收的基本语义
//! ═══════════════════════════════════════════════════════════
//!
//!  5.  单个元素 send 后可被 recv 读出，ok=true，值与写入一致
//!  6.  多个元素发送后按 FIFO 顺序读取，严格先进先出
//!  7.  环形缓冲区绕回后仍保持 FIFO：
//!      head/tail 指针绕回不影响顺序
//!  8.  发送和接收交替进行时状态正确：
//!      长度、顺序一致
//!  9.  recv 在有数据时返回 ok=true，拿到正确值
//!  10. send 在有空位时返回 ok=true
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  三、有缓冲 channel 缓冲区边界
//! ═══════════════════════════════════════════════════════════
//!
//!  11. 缓冲区未满时 send 立即返回 ok=true，不阻塞
//!  12. 恰好填满缓冲区（send capacity 次）后，所有 send 都返回 ok=true
//!  13. 缓冲区满时 send 阻塞：
//!      启动 send 线程，短暂等待后确认它仍未返回
//!  14. 缓冲区满后，另一线程 recv 取走一个值，阻塞的 send 被唤醒并成功写入
//!  15. 缓冲区为空时 recv 阻塞：
//!      启动 recv 线程，短暂等待后确认它仍未返回
//!  16. 缓冲区为空后，另一线程 send 写入一个值，阻塞的 recv 被唤醒并拿到值
//!  17. capacity=1 时行为正确：
//!      send 一个后满，再 send 阻塞；recv 后腾出空位
//!  18. ring buffer 回绕：
//!      send/recv 交替超过 capacity 次，head/tail 正确回绕，数据不错乱
//!  19. 填满再全部读空后再次填满排空，token 数量一致，不丢不多
//!  20. 同一个 channel 反复填满-排空多轮，行为始终正确，状态不残留
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  四、close 的 Go 语义
//! ═══════════════════════════════════════════════════════════
//!
//! Go 语义：close 后 send 是 panic，double close 也是 panic。
//! 本 contract 中 send after close 返回 ok=false，
//! 测试验证 ok=false 语义。
//!
//!  21. close 一个未关闭 channel 成功，channel 进入 closed 状态
//!  22. close 后 send 返回 ok=false，不能静默成功
//!  23. close 后多次 send 均返回 ok=false（幂等）
//!  24. close 后，缓冲中已有的数据仍然可以按 FIFO 继续读完（ok=true）
//!  25. close 后，缓冲耗尽时 recv 返回 ok=false，不再阻塞，不再返回旧值
//!  26. close 后对空 closed channel 连续多次 recv 都返回 ok=false（行为稳定）
//!  27. close 后 send+recv 排空完整流程：先 send 若干 -> close -> recv 全部 -> ok=false
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  五、阻塞路径与唤醒
//! ═══════════════════════════════════════════════════════════
//!
//!  28. 空 channel 上阻塞 recv，当有发送到来时被正确唤醒，收到值 ok=true
//!  29. 满缓冲 channel 上阻塞 send，当有接收到来时被正确唤醒，发送成功
//!  30. 空 channel 上阻塞 recv，close 后必须被唤醒，返回 ok=false，不能永久卡死
//!  31. 满缓冲 channel 上阻塞 send，close 后必须被唤醒，返回 ok=false
//!  32. close 唤醒所有（多个）阻塞在 recv 上的线程，它们都拿到 ok=false
//!  33. close 唤醒所有（多个）阻塞在 send 上的线程，它们都拿到 ok=false
//!  34. 交替 send/recv 大量轮次（≥10000），不死锁、不丢数据
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  六、并发正确性
//! ═══════════════════════════════════════════════════════════
//!
//!  35. 单生产者单消费者并发下不丢消息，发送数量与接收数量一致
//!  36. 多生产者单消费者并发下不丢消息，总数正确，无覆盖
//!  37. 单生产者多消费者并发下不重复投递，每个元素只被一个消费者拿到一次
//!  38. 多生产者多消费者并发下保持数据完整性：无重复、无丢失、无越界、无死锁
//!  39. 并发 close 与 recv 竞态：已有数据可读完，之后 ok=false
//!  40. 并发 close 与 send 竞态：send 返回 ok=true 或 ok=false，不能静默丢失
//!  41. 高并发压力：M 个生产者 × K 个消费者并发跑，验证无 race、无 panic
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  七、资源安全
//! ═══════════════════════════════════════════════════════════
//!
//!  42. 正常 send/recv/deinit 路径无内存泄漏
//!  43. 带未消费缓冲数据直接 deinit 无内存泄漏
//!  44. close 后 deinit 无资源泄漏
//!  45. 快速连续 close + recv 不 panic、不 hang
//!  46. 快速连续 close + send 不 panic、不 hang

const std = @import("std");
const testing = std.testing;

pub fn ChannelTestRunner(comptime Ch: type) type {
    const Event = Ch.event_t;

    return struct {
        pub const Options = struct {
            basic: bool = false,
            concurrency: bool = false,
            unbuffered: bool = false,
        };

        pub fn run(allocator: std.mem.Allocator, opts: Options) !void {
            var passed: u32 = 0;
            var failed: u32 = 0;
            const run_start = std.time.nanoTimestamp();

            if (opts.unbuffered) {
                runOne("unbufferedInit", allocator, &passed, &failed, testUnbufferedInit);
                runOne("unbufferedRendezvous", allocator, &passed, &failed, testUnbufferedRendezvous);
                runOne("unbufferedSendBlocks", allocator, &passed, &failed, testUnbufferedSendBlocks);
                runOne("unbufferedRecvBlocks", allocator, &passed, &failed, testUnbufferedRecvBlocks);
                runOne("unbufferedMultiRound", allocator, &passed, &failed, testUnbufferedMultiRound);
                runOne("unbufferedCloseWakesRecv", allocator, &passed, &failed, testUnbufferedCloseWakesRecv);
                runOne("unbufferedCloseWakesSend", allocator, &passed, &failed, testUnbufferedCloseWakesSend);
                runOne("unbufferedSendAfterClose", allocator, &passed, &failed, testUnbufferedSendAfterClose);
                runOne("unbufferedRecvAfterClose", allocator, &passed, &failed, testUnbufferedRecvAfterClose);
                runOne("unbufferedSpsc", allocator, &passed, &failed, testUnbufferedSpsc);
                runOne("unbufferedMpsc", allocator, &passed, &failed, testUnbufferedMpsc);
                runOne("unbufferedDeinit", allocator, &passed, &failed, testUnbufferedDeinit);
            }

            if (opts.basic) {
                runOne("initBuffered", allocator, &passed, &failed, testInitBuffered);
                runOne("initialStateBuffered", allocator, &passed, &failed, testInitialStateBuffered);
                runOne("deinitClean", allocator, &passed, &failed, testDeinitClean);

                runOne("sendRecvSingle", allocator, &passed, &failed, testSendRecvSingle);
                runOne("fifoOrder", allocator, &passed, &failed, testFifoOrder);
                runOne("ringWrap", allocator, &passed, &failed, testRingWrap);
                runOne("sendRecvInterleaved", allocator, &passed, &failed, testSendRecvInterleaved);
                runOne("recvReturnsCorrectValue", allocator, &passed, &failed, testRecvReturnsCorrectValue);
                runOne("sendReturnsOk", allocator, &passed, &failed, testSendReturnsOk);

                runOne("bufferedSendImmediate", allocator, &passed, &failed, testBufferedSendImmediate);
                runOne("fillBufferExactly", allocator, &passed, &failed, testFillBufferExactly);
                runOne("capacityOne", allocator, &passed, &failed, testCapacityOne);
                runOne("ringWrapExtended", allocator, &passed, &failed, testRingWrapExtended);
                runOne("fillDrainTokenBalance", allocator, &passed, &failed, testFillDrainTokenBalance);
                runOne("multiRoundFillDrain", allocator, &passed, &failed, testMultiRoundFillDrain);

                runOne("closeSuccess", allocator, &passed, &failed, testCloseSuccess);
                runOne("sendAfterClose", allocator, &passed, &failed, testSendAfterClose);
                runOne("multiSendAfterClose", allocator, &passed, &failed, testMultiSendAfterClose);
                runOne("closeFlushBufferedData", allocator, &passed, &failed, testCloseFlushBufferedData);
                runOne("recvAfterCloseEmpty", allocator, &passed, &failed, testRecvAfterCloseEmpty);
                runOne("multiRecvAfterClose", allocator, &passed, &failed, testMultiRecvAfterClose);
                runOne("closeFlushFullFlow", allocator, &passed, &failed, testCloseFlushFullFlow);

                runOne("resourceSafetyNormal", allocator, &passed, &failed, testResourceSafetyNormal);
                runOne("resourceSafetyUnconsumed", allocator, &passed, &failed, testResourceSafetyUnconsumed);
                runOne("resourceSafetyCloseAndDeinit", allocator, &passed, &failed, testResourceSafetyCloseAndDeinit);
            }

            if (opts.concurrency) {
                runOne("sendBlocksWhenFull", allocator, &passed, &failed, testSendBlocksWhenFull);
                runOne("recvUnblocksSend", allocator, &passed, &failed, testRecvUnblocksSend);
                runOne("recvBlocksWhenEmpty", allocator, &passed, &failed, testRecvBlocksWhenEmpty);
                runOne("sendUnblocksRecv", allocator, &passed, &failed, testSendUnblocksRecv);

                runOne("recvWokenBySend", allocator, &passed, &failed, testRecvWokenBySend);
                runOne("sendWokenByRecv", allocator, &passed, &failed, testSendWokenByRecv);
                runOne("recvWokenByClose", allocator, &passed, &failed, testRecvWokenByClose);
                runOne("sendWokenByClose", allocator, &passed, &failed, testSendWokenByClose);
                runOne("closeWakesMultiRecv", allocator, &passed, &failed, testCloseWakesMultiRecv);
                runOne("closeWakesMultiSend", allocator, &passed, &failed, testCloseWakesMultiSend);
                runOne("highThroughputNoDeadlock", allocator, &passed, &failed, testHighThroughputNoDeadlock);

                runOne("spscNoDrop", allocator, &passed, &failed, testSpscNoDrop);
                runOne("mpscNoDrop", allocator, &passed, &failed, testMpscNoDrop);
                runOne("spmcNoDuplicate", allocator, &passed, &failed, testSpmcNoDuplicate);
                runOne("mpmcIntegrity", allocator, &passed, &failed, testMpmcIntegrity);
                runOne("concurrentCloseRecv", allocator, &passed, &failed, testConcurrentCloseRecv);
                runOne("concurrentCloseSend", allocator, &passed, &failed, testConcurrentCloseSend);

                runOne("rapidCloseRecv", allocator, &passed, &failed, testRapidCloseRecv);
                runOne("rapidCloseSend", allocator, &passed, &failed, testRapidCloseSend);
            }

            const total_ns = std.time.nanoTimestamp() - run_start;
            const total_ms = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0;
            std.debug.print("\n── channel: {d} passed, {d} failed, total {d:.1}ms ──\n", .{ passed, failed, total_ms });

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
        //  一、初始化与基本属性 (#1-#4)
        // ═══════════════════════════════════════════════════════════

        fn testInitBuffered(allocator: std.mem.Allocator) !void {
            var ch1 = try Ch.init(allocator, 1);
            defer ch1.deinit();

            var ch64 = try Ch.init(allocator, 64);
            defer ch64.deinit();

            var ch1024 = try Ch.init(allocator, 1024);
            defer ch1024.deinit();
        }

        fn testInitialStateBuffered(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            _ = try ch.send(42);
            const r = try ch.recv();
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 42), r.value);
        }

        fn testDeinitClean(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 8);
            _ = try ch.send(1);
            _ = try ch.send(2);
            ch.deinit();
        }

        // ═══════════════════════════════════════════════════════════
        //  二、发送与接收的基本语义 (#5-#10)
        // ═══════════════════════════════════════════════════════════

        fn testSendRecvSingle(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            const s = try ch.send(99);
            try testing.expect(s.ok);

            const r = try ch.recv();
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 99), r.value);
        }

        fn testFifoOrder(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 8);
            defer ch.deinit();

            for (0..8) |i| {
                const s = try ch.send(@intCast(i));
                try testing.expect(s.ok);
            }

            for (0..8) |i| {
                const r = try ch.recv();
                try testing.expect(r.ok);
                try testing.expectEqual(@as(Event, @intCast(i)), r.value);
            }
        }

        fn testRingWrap(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            for (0..10) |i| {
                const s = try ch.send(@intCast(i));
                try testing.expect(s.ok);
                const r = try ch.recv();
                try testing.expect(r.ok);
                try testing.expectEqual(@as(Event, @intCast(i)), r.value);
            }
        }

        fn testSendRecvInterleaved(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            _ = try ch.send(10);
            _ = try ch.send(20);

            const r1 = try ch.recv();
            try testing.expect(r1.ok);
            try testing.expectEqual(@as(Event, 10), r1.value);

            _ = try ch.send(30);

            const r2 = try ch.recv();
            try testing.expect(r2.ok);
            try testing.expectEqual(@as(Event, 20), r2.value);

            const r3 = try ch.recv();
            try testing.expect(r3.ok);
            try testing.expectEqual(@as(Event, 30), r3.value);
        }

        fn testRecvReturnsCorrectValue(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            _ = try ch.send(0xAB);
            const r = try ch.recv();
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 0xAB), r.value);
        }

        fn testSendReturnsOk(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            const s = try ch.send(1);
            try testing.expect(s.ok);

            const r = try ch.recv();
            try testing.expect(r.ok);
        }

        // ═══════════════════════════════════════════════════════════
        //  三、有缓冲 channel 缓冲区边界 (#11-#20)
        // ═══════════════════════════════════════════════════════════

        fn testBufferedSendImmediate(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 8);
            defer ch.deinit();

            const s = try ch.send(1);
            try testing.expect(s.ok);
        }

        fn testFillBufferExactly(allocator: std.mem.Allocator) !void {
            const cap = 8;
            var ch = try Ch.init(allocator, cap);
            defer ch.deinit();

            for (0..cap) |i| {
                const s = try ch.send(@intCast(i));
                try testing.expect(s.ok);
            }
        }

        fn testSendBlocksWhenFull(allocator: std.mem.Allocator) !void {
            const cap = 4;
            var ch = try Ch.init(allocator, cap);
            defer ch.deinit();

            for (0..cap) |i| {
                _ = try ch.send(@intCast(i));
            }

            var entered = std.atomic.Value(bool).init(false);
            var finished = std.atomic.Value(bool).init(false);
            const t = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch, ent: *std.atomic.Value(bool), fin: *std.atomic.Value(bool)) void {
                    ent.store(true, .release);
                    _ = c.send(0xFF) catch {};
                    fin.store(true, .release);
                }
            }.run, .{ &ch, &entered, &finished });

            std.Thread.sleep(80 * std.time.ns_per_ms);
            try testing.expect(entered.load(.acquire));
            try testing.expect(!finished.load(.acquire));

            _ = try ch.recv();
            t.join();
            try testing.expect(finished.load(.acquire));
        }

        fn testRecvUnblocksSend(allocator: std.mem.Allocator) !void {
            const cap = 2;
            var ch = try Ch.init(allocator, cap);
            defer ch.deinit();

            _ = try ch.send(1);
            _ = try ch.send(2);

            var send_ok = std.atomic.Value(bool).init(false);
            const t = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch, flag: *std.atomic.Value(bool)) void {
                    const s = c.send(3) catch return;
                    flag.store(s.ok, .release);
                }
            }.run, .{ &ch, &send_ok });

            std.Thread.sleep(30 * std.time.ns_per_ms);

            const r = try ch.recv();
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 1), r.value);

            t.join();
            try testing.expect(send_ok.load(.acquire));

            const r2 = try ch.recv();
            try testing.expect(r2.ok);
            try testing.expectEqual(@as(Event, 2), r2.value);

            const r3 = try ch.recv();
            try testing.expect(r3.ok);
            try testing.expectEqual(@as(Event, 3), r3.value);
        }

        fn testRecvBlocksWhenEmpty(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            var entered = std.atomic.Value(bool).init(false);
            var finished = std.atomic.Value(bool).init(false);
            const t = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch, ent: *std.atomic.Value(bool), fin: *std.atomic.Value(bool)) void {
                    ent.store(true, .release);
                    _ = c.recv() catch {};
                    fin.store(true, .release);
                }
            }.run, .{ &ch, &entered, &finished });

            std.Thread.sleep(80 * std.time.ns_per_ms);
            try testing.expect(entered.load(.acquire));
            try testing.expect(!finished.load(.acquire));

            _ = try ch.send(42);
            t.join();
            try testing.expect(finished.load(.acquire));
        }

        fn testSendUnblocksRecv(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            var recv_ok = std.atomic.Value(bool).init(false);
            var recv_val = std.atomic.Value(Event).init(0);
            const t = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch, ok_flag: *std.atomic.Value(bool), val_flag: *std.atomic.Value(Event)) void {
                    const r = c.recv() catch return;
                    if (r.ok) {
                        val_flag.store(r.value, .release);
                        ok_flag.store(true, .release);
                    }
                }
            }.run, .{ &ch, &recv_ok, &recv_val });

            std.Thread.sleep(30 * std.time.ns_per_ms);
            _ = try ch.send(0xBEEF);
            t.join();

            try testing.expect(recv_ok.load(.acquire));
            try testing.expectEqual(@as(Event, 0xBEEF), recv_val.load(.acquire));
        }

        fn testCapacityOne(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 1);
            defer ch.deinit();

            const s = try ch.send(10);
            try testing.expect(s.ok);

            const r = try ch.recv();
            try testing.expect(r.ok);
            try testing.expectEqual(@as(Event, 10), r.value);

            _ = try ch.send(30);
            const r2 = try ch.recv();
            try testing.expect(r2.ok);
            try testing.expectEqual(@as(Event, 30), r2.value);
        }

        fn testRingWrapExtended(allocator: std.mem.Allocator) !void {
            const cap = 4;
            var ch = try Ch.init(allocator, cap);
            defer ch.deinit();

            for (0..cap * 3) |i| {
                _ = try ch.send(@intCast(i));
                const r = try ch.recv();
                try testing.expect(r.ok);
                try testing.expectEqual(@as(Event, @intCast(i)), r.value);
            }
        }

        fn testFillDrainTokenBalance(allocator: std.mem.Allocator) !void {
            const cap = 8;
            var ch = try Ch.init(allocator, cap);
            defer ch.deinit();

            for (0..cap) |i| {
                _ = try ch.send(@intCast(i));
            }
            for (0..cap) |_| {
                const r = try ch.recv();
                try testing.expect(r.ok);
            }

            for (0..cap) |i| {
                _ = try ch.send(@intCast(i));
            }
            for (0..cap) |_| {
                const r = try ch.recv();
                try testing.expect(r.ok);
            }
        }

        fn testMultiRoundFillDrain(allocator: std.mem.Allocator) !void {
            const cap = 4;
            var ch = try Ch.init(allocator, cap);
            defer ch.deinit();

            for (0..5) |round| {
                for (0..cap) |i| {
                    const val: Event = @intCast(round * cap + i);
                    _ = try ch.send(val);
                }
                for (0..cap) |i| {
                    const r = try ch.recv();
                    try testing.expect(r.ok);
                    const expected: Event = @intCast(round * cap + i);
                    try testing.expectEqual(expected, r.value);
                }
            }
        }

        // ═══════════════════════════════════════════════════════════
        //  四、close 的 Go 语义 (#21-#27)
        // ═══════════════════════════════════════════════════════════

        fn testCloseSuccess(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();
            ch.close();
        }

        fn testSendAfterClose(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();
            ch.close();

            const s = try ch.send(1);
            try testing.expect(!s.ok);
        }

        fn testMultiSendAfterClose(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();
            ch.close();

            for (0..5) |i| {
                const s = try ch.send(@intCast(i));
                try testing.expect(!s.ok);
            }
        }

        fn testCloseFlushBufferedData(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 8);
            defer ch.deinit();

            _ = try ch.send(10);
            _ = try ch.send(20);
            _ = try ch.send(30);
            ch.close();

            const r1 = try ch.recv();
            try testing.expect(r1.ok);
            try testing.expectEqual(@as(Event, 10), r1.value);

            const r2 = try ch.recv();
            try testing.expect(r2.ok);
            try testing.expectEqual(@as(Event, 20), r2.value);

            const r3 = try ch.recv();
            try testing.expect(r3.ok);
            try testing.expectEqual(@as(Event, 30), r3.value);
        }

        fn testRecvAfterCloseEmpty(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();
            ch.close();

            const r = try ch.recv();
            try testing.expect(!r.ok);
        }

        fn testMultiRecvAfterClose(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();
            ch.close();

            for (0..5) |_| {
                const r = try ch.recv();
                try testing.expect(!r.ok);
            }
        }

        fn testCloseFlushFullFlow(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 8);
            defer ch.deinit();

            for (0..5) |i| {
                _ = try ch.send(@intCast(i));
            }
            ch.close();

            for (0..5) |i| {
                const r = try ch.recv();
                try testing.expect(r.ok);
                try testing.expectEqual(@as(Event, @intCast(i)), r.value);
            }

            const r_end = try ch.recv();
            try testing.expect(!r_end.ok);
        }

        // ═══════════════════════════════════════════════════════════
        //  五、阻塞路径与唤醒 (#28-#34)
        // ═══════════════════════════════════════════════════════════

        fn testRecvWokenBySend(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            var recv_ok = std.atomic.Value(bool).init(false);
            var recv_val = std.atomic.Value(Event).init(0);
            const t = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch, ok_flag: *std.atomic.Value(bool), val_flag: *std.atomic.Value(Event)) void {
                    const r = c.recv() catch return;
                    if (r.ok) {
                        val_flag.store(r.value, .release);
                        ok_flag.store(true, .release);
                    }
                }
            }.run, .{ &ch, &recv_ok, &recv_val });

            std.Thread.sleep(50 * std.time.ns_per_ms);
            _ = try ch.send(0xCAFE);
            t.join();

            try testing.expect(recv_ok.load(.acquire));
            try testing.expectEqual(@as(Event, 0xCAFE), recv_val.load(.acquire));
        }

        fn testSendWokenByRecv(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 2);
            defer ch.deinit();

            _ = try ch.send(1);
            _ = try ch.send(2);

            var send_ok = std.atomic.Value(bool).init(false);
            const t = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch, flag: *std.atomic.Value(bool)) void {
                    const s = c.send(3) catch return;
                    flag.store(s.ok, .release);
                }
            }.run, .{ &ch, &send_ok });

            std.Thread.sleep(50 * std.time.ns_per_ms);
            _ = try ch.recv();
            t.join();

            try testing.expect(send_ok.load(.acquire));
        }

        fn testRecvWokenByClose(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            var recv_ok = std.atomic.Value(bool).init(true);
            const t = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch, flag: *std.atomic.Value(bool)) void {
                    const r = c.recv() catch {
                        flag.store(false, .release);
                        return;
                    };
                    flag.store(r.ok, .release);
                }
            }.run, .{ &ch, &recv_ok });

            std.Thread.sleep(50 * std.time.ns_per_ms);
            ch.close();
            t.join();

            try testing.expect(!recv_ok.load(.acquire));
        }

        fn testSendWokenByClose(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 2);
            defer ch.deinit();

            _ = try ch.send(1);
            _ = try ch.send(2);

            var send_ok = std.atomic.Value(bool).init(true);
            const t = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch, flag: *std.atomic.Value(bool)) void {
                    const s = c.send(99) catch {
                        flag.store(false, .release);
                        return;
                    };
                    flag.store(s.ok, .release);
                }
            }.run, .{ &ch, &send_ok });

            std.Thread.sleep(50 * std.time.ns_per_ms);
            ch.close();
            t.join();

            try testing.expect(!send_ok.load(.acquire));
        }

        fn testCloseWakesMultiRecv(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            const N = 4;
            var done_count = std.atomic.Value(u32).init(0);
            var threads: [N]std.Thread = undefined;

            for (0..N) |i| {
                threads[i] = try std.Thread.spawn(.{}, struct {
                    fn run(c: *Ch, cnt: *std.atomic.Value(u32)) void {
                        const r = c.recv() catch {
                            _ = cnt.fetchAdd(1, .acq_rel);
                            return;
                        };
                        if (!r.ok) {
                            _ = cnt.fetchAdd(1, .acq_rel);
                        }
                    }
                }.run, .{ &ch, &done_count });
            }

            std.Thread.sleep(80 * std.time.ns_per_ms);
            ch.close();

            for (0..N) |i| {
                threads[i].join();
            }

            try testing.expectEqual(@as(u32, N), done_count.load(.acquire));
        }

        fn testCloseWakesMultiSend(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 2);
            defer ch.deinit();

            _ = try ch.send(1);
            _ = try ch.send(2);

            const N = 4;
            var done_count = std.atomic.Value(u32).init(0);
            var threads: [N]std.Thread = undefined;

            for (0..N) |i| {
                threads[i] = try std.Thread.spawn(.{}, struct {
                    fn run(c: *Ch, cnt: *std.atomic.Value(u32)) void {
                        const s = c.send(99) catch {
                            _ = cnt.fetchAdd(1, .acq_rel);
                            return;
                        };
                        if (!s.ok) {
                            _ = cnt.fetchAdd(1, .acq_rel);
                        }
                    }
                }.run, .{ &ch, &done_count });
            }

            std.Thread.sleep(80 * std.time.ns_per_ms);
            ch.close();

            for (0..N) |i| {
                threads[i].join();
            }

            try testing.expectEqual(@as(u32, N), done_count.load(.acquire));
        }

        fn testHighThroughputNoDeadlock(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 64);
            defer ch.deinit();

            const COUNT = 10_000;

            const sender = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch) void {
                    for (0..COUNT) |i| {
                        _ = c.send(@intCast(i)) catch return;
                    }
                }
            }.run, .{&ch});

            var received: u32 = 0;
            for (0..COUNT) |_| {
                const r = try ch.recv();
                if (r.ok) received += 1;
            }

            sender.join();
            try testing.expectEqual(@as(u32, COUNT), received);
        }

        // ═══════════════════════════════════════════════════════════
        //  六、并发正确性 (#35-#41)
        // ═══════════════════════════════════════════════════════════

        fn testSpscNoDrop(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 32);
            defer ch.deinit();

            const N = 1000;

            const sender = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch) void {
                    for (0..N) |i| {
                        _ = c.send(@intCast(i)) catch return;
                    }
                }
            }.run, .{&ch});

            var count: u32 = 0;
            while (count < N) {
                const r = try ch.recv();
                if (r.ok) {
                    try testing.expectEqual(@as(Event, @intCast(count)), r.value);
                    count += 1;
                }
            }

            sender.join();
        }

        fn testMpscNoDrop(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 32);
            defer ch.deinit();

            const PRODUCERS = 4;
            const PER_PRODUCER = 250;
            const TOTAL = PRODUCERS * PER_PRODUCER;

            var threads: [PRODUCERS]std.Thread = undefined;
            for (0..PRODUCERS) |p| {
                threads[p] = try std.Thread.spawn(.{}, struct {
                    fn run(c: *Ch, base: u32) void {
                        for (0..PER_PRODUCER) |i| {
                            _ = c.send(@intCast(base + @as(u32, @intCast(i)))) catch return;
                        }
                    }
                }.run, .{ &ch, @as(u32, @intCast(p * PER_PRODUCER)) });
            }

            var seen = [_]bool{false} ** TOTAL;
            var count: u32 = 0;
            while (count < TOTAL) {
                const r = try ch.recv();
                if (r.ok) {
                    const idx: usize = @intCast(r.value);
                    try testing.expect(!seen[idx]);
                    seen[idx] = true;
                    count += 1;
                }
            }

            for (0..PRODUCERS) |p| {
                threads[p].join();
            }

            for (seen) |s| {
                try testing.expect(s);
            }
        }

        fn testSpmcNoDuplicate(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 32);
            defer ch.deinit();

            const CONSUMERS = 4;
            const TOTAL = 1000;

            const sender = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch) void {
                    for (0..TOTAL) |i| {
                        _ = c.send(@intCast(i)) catch return;
                    }
                    c.close();
                }
            }.run, .{&ch});

            var global_count = std.atomic.Value(u32).init(0);
            var consumers: [CONSUMERS]std.Thread = undefined;
            for (0..CONSUMERS) |c| {
                consumers[c] = try std.Thread.spawn(.{}, struct {
                    fn run(channel: *Ch, cnt: *std.atomic.Value(u32)) void {
                        while (true) {
                            const r = channel.recv() catch return;
                            if (!r.ok) break;
                            _ = cnt.fetchAdd(1, .acq_rel);
                        }
                    }
                }.run, .{ &ch, &global_count });
            }

            sender.join();
            for (0..CONSUMERS) |c| {
                consumers[c].join();
            }

            try testing.expectEqual(@as(u32, TOTAL), global_count.load(.acquire));
        }

        fn testMpmcIntegrity(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 64);
            defer ch.deinit();

            const PRODUCERS = 4;
            const CONSUMERS = 4;
            const PER_PRODUCER = 500;
            const TOTAL = PRODUCERS * PER_PRODUCER;

            var prod_threads: [PRODUCERS]std.Thread = undefined;
            for (0..PRODUCERS) |p| {
                prod_threads[p] = try std.Thread.spawn(.{}, struct {
                    fn run(c: *Ch, base: u32) void {
                        for (0..PER_PRODUCER) |i| {
                            _ = c.send(@intCast(base + @as(u32, @intCast(i)))) catch return;
                        }
                    }
                }.run, .{ &ch, @as(u32, @intCast(p * PER_PRODUCER)) });
            }

            var global_count = std.atomic.Value(u32).init(0);
            var cons_threads: [CONSUMERS]std.Thread = undefined;
            for (0..CONSUMERS) |c| {
                cons_threads[c] = try std.Thread.spawn(.{}, struct {
                    fn run(channel: *Ch, cnt: *std.atomic.Value(u32)) void {
                        while (cnt.load(.acquire) < TOTAL) {
                            const r = channel.recv() catch return;
                            if (!r.ok) return;
                            _ = cnt.fetchAdd(1, .acq_rel);
                        }
                    }
                }.run, .{ &ch, &global_count });
            }

            for (0..PRODUCERS) |p| {
                prod_threads[p].join();
            }

            var wait_ms: u32 = 0;
            while (global_count.load(.acquire) < TOTAL and wait_ms < 5000) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                wait_ms += 1;
            }

            ch.close();

            for (0..CONSUMERS) |c| {
                cons_threads[c].join();
            }

            try testing.expectEqual(@as(u32, TOTAL), global_count.load(.acquire));
        }

        fn testConcurrentCloseRecv(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 8);
            defer ch.deinit();

            _ = try ch.send(10);
            _ = try ch.send(20);
            _ = try ch.send(30);

            var recv_count = std.atomic.Value(u32).init(0);
            const N = 4;
            var threads: [N]std.Thread = undefined;

            for (0..N) |i| {
                threads[i] = try std.Thread.spawn(.{}, struct {
                    fn run(c: *Ch, cnt: *std.atomic.Value(u32)) void {
                        while (true) {
                            const r = c.recv() catch return;
                            if (!r.ok) return;
                            _ = cnt.fetchAdd(1, .acq_rel);
                        }
                    }
                }.run, .{ &ch, &recv_count });
            }

            std.Thread.sleep(30 * std.time.ns_per_ms);
            ch.close();

            for (0..N) |i| {
                threads[i].join();
            }

            try testing.expectEqual(@as(u32, 3), recv_count.load(.acquire));
        }

        fn testConcurrentCloseSend(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            var send_ok_count = std.atomic.Value(u32).init(0);
            var send_fail_count = std.atomic.Value(u32).init(0);
            const N = 8;
            var threads: [N]std.Thread = undefined;

            for (0..N) |i| {
                threads[i] = try std.Thread.spawn(.{}, struct {
                    fn run(c: *Ch, ok_cnt: *std.atomic.Value(u32), fail_cnt: *std.atomic.Value(u32)) void {
                        const s = c.send(42) catch {
                            _ = fail_cnt.fetchAdd(1, .acq_rel);
                            return;
                        };
                        if (s.ok) {
                            _ = ok_cnt.fetchAdd(1, .acq_rel);
                        } else {
                            _ = fail_cnt.fetchAdd(1, .acq_rel);
                        }
                    }
                }.run, .{ &ch, &send_ok_count, &send_fail_count });
            }

            std.Thread.sleep(30 * std.time.ns_per_ms);
            ch.close();

            for (0..N) |i| {
                threads[i].join();
            }

            const ok = send_ok_count.load(.acquire);
            const fail = send_fail_count.load(.acquire);
            try testing.expectEqual(@as(u32, N), ok + fail);
        }

        // ═══════════════════════════════════════════════════════════
        //  七、资源安全 (#42-#46)
        // ═══════════════════════════════════════════════════════════

        fn testResourceSafetyNormal(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 8);
            _ = try ch.send(1);
            _ = try ch.send(2);
            _ = try ch.recv();
            _ = try ch.recv();
            ch.deinit();
        }

        fn testResourceSafetyUnconsumed(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 8);
            _ = try ch.send(1);
            _ = try ch.send(2);
            _ = try ch.send(3);
            ch.deinit();
        }

        fn testResourceSafetyCloseAndDeinit(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 8);
            _ = try ch.send(1);
            ch.close();
            ch.deinit();
        }

        fn testRapidCloseRecv(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            ch.close();
            for (0..10) |_| {
                const r = try ch.recv();
                try testing.expect(!r.ok);
            }
        }

        fn testRapidCloseSend(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 4);
            defer ch.deinit();

            ch.close();
            for (0..10) |_| {
                const s = try ch.send(1);
                try testing.expect(!s.ok);
            }
        }

        // ═══════════════════════════════════════════════════════════
        //  〇、无缓冲 channel (U1-U12)
        // ═══════════════════════════════════════════════════════════

        fn testUnbufferedInit(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 0);
            defer ch.deinit();
        }

        fn testUnbufferedRendezvous(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 0);
            defer ch.deinit();

            var recv_val = std.atomic.Value(Event).init(0);
            var recv_ok = std.atomic.Value(bool).init(false);
            const t = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch, val: *std.atomic.Value(Event), ok: *std.atomic.Value(bool)) void {
                    const r = c.recv() catch return;
                    if (r.ok) {
                        val.store(r.value, .release);
                        ok.store(true, .release);
                    }
                }
            }.run, .{ &ch, &recv_val, &recv_ok });

            std.Thread.sleep(30 * std.time.ns_per_ms);
            const s = try ch.send(0xDEAD);
            try testing.expect(s.ok);
            t.join();

            try testing.expect(recv_ok.load(.acquire));
            try testing.expectEqual(@as(Event, 0xDEAD), recv_val.load(.acquire));
        }

        fn testUnbufferedSendBlocks(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 0);
            defer ch.deinit();

            var entered = std.atomic.Value(bool).init(false);
            var finished = std.atomic.Value(bool).init(false);
            const t = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch, ent: *std.atomic.Value(bool), fin: *std.atomic.Value(bool)) void {
                    ent.store(true, .release);
                    _ = c.send(1) catch {};
                    fin.store(true, .release);
                }
            }.run, .{ &ch, &entered, &finished });

            std.Thread.sleep(80 * std.time.ns_per_ms);
            try testing.expect(entered.load(.acquire));
            try testing.expect(!finished.load(.acquire));

            _ = try ch.recv();
            t.join();
            try testing.expect(finished.load(.acquire));
        }

        fn testUnbufferedRecvBlocks(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 0);
            defer ch.deinit();

            var entered = std.atomic.Value(bool).init(false);
            var finished = std.atomic.Value(bool).init(false);
            const t = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch, ent: *std.atomic.Value(bool), fin: *std.atomic.Value(bool)) void {
                    ent.store(true, .release);
                    _ = c.recv() catch {};
                    fin.store(true, .release);
                }
            }.run, .{ &ch, &entered, &finished });

            std.Thread.sleep(80 * std.time.ns_per_ms);
            try testing.expect(entered.load(.acquire));
            try testing.expect(!finished.load(.acquire));

            _ = try ch.send(42);
            t.join();
            try testing.expect(finished.load(.acquire));
        }

        fn testUnbufferedMultiRound(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 0);
            defer ch.deinit();

            const N = 100;
            const receiver = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch) !void {
                    for (0..N) |i| {
                        const r = try c.recv();
                        try testing.expect(r.ok);
                        try testing.expectEqual(@as(Event, @intCast(i)), r.value);
                    }
                }
            }.run, .{&ch});

            for (0..N) |i| {
                const s = try ch.send(@intCast(i));
                try testing.expect(s.ok);
            }
            receiver.join();
        }

        fn testUnbufferedCloseWakesRecv(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 0);
            defer ch.deinit();

            var recv_ok = std.atomic.Value(bool).init(true);
            const t = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch, flag: *std.atomic.Value(bool)) void {
                    const r = c.recv() catch {
                        flag.store(false, .release);
                        return;
                    };
                    flag.store(r.ok, .release);
                }
            }.run, .{ &ch, &recv_ok });

            std.Thread.sleep(50 * std.time.ns_per_ms);
            ch.close();
            t.join();

            try testing.expect(!recv_ok.load(.acquire));
        }

        fn testUnbufferedCloseWakesSend(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 0);
            defer ch.deinit();

            var send_ok = std.atomic.Value(bool).init(true);
            const t = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch, flag: *std.atomic.Value(bool)) void {
                    const s = c.send(99) catch {
                        flag.store(false, .release);
                        return;
                    };
                    flag.store(s.ok, .release);
                }
            }.run, .{ &ch, &send_ok });

            std.Thread.sleep(50 * std.time.ns_per_ms);
            ch.close();
            t.join();

            try testing.expect(!send_ok.load(.acquire));
        }

        fn testUnbufferedSendAfterClose(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 0);
            defer ch.deinit();
            ch.close();

            const s = try ch.send(1);
            try testing.expect(!s.ok);
        }

        fn testUnbufferedRecvAfterClose(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 0);
            defer ch.deinit();
            ch.close();

            const r = try ch.recv();
            try testing.expect(!r.ok);
        }

        fn testUnbufferedSpsc(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 0);
            defer ch.deinit();

            const N = 500;
            const sender = try std.Thread.spawn(.{}, struct {
                fn run(c: *Ch) void {
                    for (0..N) |i| {
                        _ = c.send(@intCast(i)) catch return;
                    }
                }
            }.run, .{&ch});

            var count: u32 = 0;
            while (count < N) {
                const r = try ch.recv();
                if (r.ok) {
                    try testing.expectEqual(@as(Event, @intCast(count)), r.value);
                    count += 1;
                }
            }
            sender.join();
        }

        fn testUnbufferedMpsc(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 0);
            defer ch.deinit();

            const PRODUCERS = 4;
            const PER_PRODUCER = 100;
            const TOTAL = PRODUCERS * PER_PRODUCER;

            var threads: [PRODUCERS]std.Thread = undefined;
            for (0..PRODUCERS) |p| {
                threads[p] = try std.Thread.spawn(.{}, struct {
                    fn run(c: *Ch, base: u32) void {
                        for (0..PER_PRODUCER) |i| {
                            _ = c.send(@intCast(base + @as(u32, @intCast(i)))) catch return;
                        }
                    }
                }.run, .{ &ch, @as(u32, @intCast(p * PER_PRODUCER)) });
            }

            var seen = [_]bool{false} ** TOTAL;
            var count: u32 = 0;
            while (count < TOTAL) {
                const r = try ch.recv();
                if (r.ok) {
                    const idx: usize = @intCast(r.value);
                    try testing.expect(!seen[idx]);
                    seen[idx] = true;
                    count += 1;
                }
            }

            for (0..PRODUCERS) |p| {
                threads[p].join();
            }
            for (seen) |s| {
                try testing.expect(s);
            }
        }

        fn testUnbufferedDeinit(allocator: std.mem.Allocator) !void {
            var ch = try Ch.init(allocator, 0);
            ch.deinit();

            var ch2 = try Ch.init(allocator, 0);
            ch2.close();
            ch2.deinit();
        }
    };
}
