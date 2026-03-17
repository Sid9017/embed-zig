//! Event bus — comptime-generated event union with middleware chain.
//!
//! Bus(input_spec, output_spec, ChannelFactory) generates:
//!
//!   - `InputEvent`: tagged union from input_spec
//!   - `BusEvent`:   tagged union = `{ .input: InputEvent } ∪ output_spec`
//!
//! Peripherals push raw events via `bus.Injector(.tag)`.
//!
//! Two kinds of middleware:
//!
//! 1. Processor(input_tag, output_tag, Impl) — typed adapter for a specific
//!    input/output pair. Impl works on concrete payload types.
//!
//! 2. Middleware(Impl) — generic middleware that operates on BusEvent directly.
//!
//! Both require Impl to have:
//!   pub fn init(allocator) !*Impl
//!   pub fn deinit(*Impl) void
//!   pub fn process(*Impl, ..., yield_ctx, yield) void
//!   pub fn tick(*Impl, yield_ctx, yield) void
//!
//! Logger(Log) is built on Middleware() — logs all events then yields unchanged.
//!
//! yield is called 0~N times per invocation to emit output events.
//! `run()` drives the chain: in_ch → middlewares → out_ch. `recv()` reads out_ch.
//!
//! Example:
//!
//!   const MyBus = Bus(.{
//!       .btn_boot = button.RawEvent,
//!       .btn_vol  = button.RawEvent,
//!   }, .{
//!       .gesture = button.GestureEvent,
//!   }, Channel);
//!
//!   var bus = try MyBus.init(allocator, 16);
//!   var btn = GpioButton.init(&gpio, time, cfg, bus.Injector(.btn_boot));
//!
//!   // Typed processor: RawEvent → GestureEvent
//!   const gp = try MyBus.Processor(.btn_boot, .gesture, ButtonGesture(Time)).init(allocator);
//!   defer gp.deinit();
//!   bus.use(gp);
//!
//!   // Generic middleware: Logger
//!   const log_mw = try MyBus.Logger(Board.Log).init(allocator);
//!   defer log_mw.deinit();
//!   bus.use(log_mw);
//!
//!   const r = try bus.recv();

const std = @import("std");
const log_mod = @import("../../runtime/log.zig");
const time_mod = @import("../../runtime/time.zig");
const channel_factory_mod = @import("../../runtime/channel_factory.zig");

/// Type-erased callback for injecting a single event type into the bus.
/// Peripherals receive an EventInjector from `bus.Injector(.tag)` and call
/// `invoke(event)` to push events without knowing Bus internals.
pub fn EventInjector(comptime T: type) type {
    return struct {
        ctx: ?*anyopaque = null,
        call: *const fn (ctx: ?*anyopaque, event: T) void,

        pub fn invoke(self: @This(), event: T) void {
            self.call(self.ctx, event);
        }
    };
}

/// Comptime-generated event bus with middleware chain.
///
/// `input` spec defines peripheral input events (e.g. `.btn = RawEvent`).
/// `.tick = u64` is automatically appended to the input union.
/// `output` spec defines middleware output events (e.g. `.gesture = GestureEvent`).
/// `ChannelFactory` is the runtime channel factory (sealed by channel_factory.ChannelFactory).
///
/// The bus generates `InputEvent` (from input) and `BusEvent` (`{ .input } ∪ output`),
/// then drives events through a registered middleware chain: in_ch → middlewares → out_ch.
pub fn Bus(
    comptime input: anytype,
    comptime output: anytype,
    comptime ChannelFactory: type,
) type {
    const input_info = @typeInfo(@TypeOf(input)).@"struct";
    const output_info = @typeInfo(@TypeOf(output)).@"struct";
    if (input_info.fields.len == 0) @compileError("Bus input spec must have at least one field");
    if (output_info.fields.len == 0) @compileError("Bus output spec must have at least one field");

    comptime {
        _ = channel_factory_mod.is(ChannelFactory);
        for (input_info.fields) |f| {
            if (std.mem.eql(u8, f.name, "tick")) {
                @compileError("Bus input spec must not contain .tick — it is added automatically");
            }
        }
    }

    return struct {
        const Self = @This();

        // --- pub types ---

        /// Tagged union of all input event types, generated from input_spec + `.tick = u64`.
        pub const InputEvent = GenInputType(input_info.fields, input);

        /// Tag enum for InputEvent variants.
        pub const InputEventTag = std.meta.Tag(InputEvent);

        /// Tagged union of `{ .input: InputEvent } ∪ output_spec`.
        pub const BusEvent = BusEventType(InputEvent, output);

        /// Tag enum for BusEvent variants.
        pub const BusEventTag = std.meta.Tag(BusEvent);

        /// Result from recv(): the event value and whether the channel is still open.
        pub const RecvResult = struct { value: BusEvent, ok: bool };

        /// Result from inject(): whether the send succeeded.
        pub const SendResult = struct { ok: bool };

        /// Typed middleware adapter: maps a specific input tag to an output tag.
        /// Impl operates on concrete payload types (InPayload → OutPayload).
        ///
        /// Impl contract:
        ///   pub fn init() Impl
        ///   pub fn deinit(*Impl) void
        ///   pub fn process(*Impl, InPayload, ?*anyopaque, fn(?*anyopaque, OutPayload) void) void
        ///   pub fn tick(*Impl, ?*anyopaque, fn(?*anyopaque, OutPayload) void) void
        pub fn Processor(
            comptime input_tag: InputEventTag,
            comptime output_tag: BusEventTag,
            comptime Impl: type,
        ) type {
            const InPayload = std.meta.TagPayload(InputEvent, input_tag);
            const OutPayload = std.meta.TagPayload(BusEvent, output_tag);
            const OutYield = *const fn (?*anyopaque, OutPayload) void;

            comptime {
                _ = @as(*const fn () Impl, &Impl.init);
                _ = @as(*const fn (*Impl) void, &Impl.deinit);
                _ = @as(*const fn (*Impl, InPayload, ?*anyopaque, OutYield) void, &Impl.process);
                _ = @as(*const fn (*Impl, ?*anyopaque, OutYield) void, &Impl.tick);
            }

            return struct {
                const P = @This();
                const seal: MiddlewareSeal = .{};

                impl: Impl,
                allocator: std.mem.Allocator,

                pub fn init(allocator: std.mem.Allocator) !*P {
                    const self = try allocator.create(P);
                    self.* = .{ .impl = Impl.init(), .allocator = allocator };
                    return self;
                }

                pub fn deinit(self: *P) void {
                    self.impl.deinit();
                    self.allocator.destroy(self);
                }

                pub fn dispatchFn(ctx: ?*anyopaque, ev: BusEvent, yield_ctx: ?*anyopaque, yield: YieldFn) void {
                    const self: *P = @ptrCast(@alignCast(ctx orelse return));

                    if (ev == .input) {
                        const input_ev = ev.input;

                        if (std.meta.activeTag(input_ev) == input_tag) {
                            const payload = @field(input_ev, @tagName(input_tag));
                            var wrapper = YieldWrapper{ .yield_ctx = yield_ctx, .yield = yield };
                            self.impl.process(payload, @ptrCast(&wrapper), wrapYield);
                            return;
                        }

                        if (std.meta.activeTag(input_ev) == .tick) {
                            var wrapper = YieldWrapper{ .yield_ctx = yield_ctx, .yield = yield };
                            self.impl.tick(@ptrCast(&wrapper), wrapYield);
                            return;
                        }
                    }

                    yield(yield_ctx, ev);
                }

                const YieldWrapper = struct {
                    yield_ctx: ?*anyopaque,
                    yield: YieldFn,
                };

                fn wrapYield(wrapper_ctx: ?*anyopaque, out: OutPayload) void {
                    const wrapper: *const YieldWrapper = @ptrCast(@alignCast(wrapper_ctx orelse return));
                    const bus_ev = @unionInit(BusEvent, @tagName(output_tag), out);
                    wrapper.yield(wrapper.yield_ctx, bus_ev);
                }
            };
        }

        /// Generic middleware: Impl operates directly on BusEvent.
        ///
        /// Impl contract:
        ///   pub fn init() Impl
        ///   pub fn deinit(*Impl) void
        ///   pub fn process(*Impl, BusEvent, ?*anyopaque, fn(?*anyopaque, BusEvent) void) void
        ///   pub fn tick(*Impl, ?*anyopaque, fn(?*anyopaque, BusEvent) void) void
        pub fn Middleware(comptime Impl: type) type {
            comptime {
                _ = @as(*const fn () Impl, &Impl.init);
                _ = @as(*const fn (*Impl) void, &Impl.deinit);
                _ = @as(*const fn (*Impl, BusEvent, ?*anyopaque, YieldFn) void, &Impl.process);
                _ = @as(*const fn (*Impl, ?*anyopaque, YieldFn) void, &Impl.tick);
            }

            return struct {
                const P = @This();
                const seal: MiddlewareSeal = .{};

                impl: Impl,
                allocator: std.mem.Allocator,

                pub fn init(allocator: std.mem.Allocator) !*P {
                    const self = try allocator.create(P);
                    self.* = .{ .impl = Impl.init(), .allocator = allocator };
                    return self;
                }

                pub fn deinit(self: *P) void {
                    self.impl.deinit();
                    self.allocator.destroy(self);
                }

                pub fn dispatchFn(ctx: ?*anyopaque, ev: BusEvent, yield_ctx: ?*anyopaque, yield: YieldFn) void {
                    const self: *P = @ptrCast(@alignCast(ctx orelse return));

                    if (ev == .input and std.meta.activeTag(ev.input) == .tick) {
                        self.impl.tick(yield_ctx, yield);
                        return;
                    }

                    self.impl.process(ev, yield_ctx, yield);
                }
            };
        }

        /// Built-in logger middleware. Logs all BusEvents then yields unchanged.
        /// Log must satisfy the runtime.log contract.
        pub fn Logger(comptime Log: type) type {
            const LogType = log_mod.is(Log);

            return Middleware(struct {
                const log: LogType = .{};

                pub fn init() @This() {
                    return .{};
                }

                pub fn deinit(_: *@This()) void {}

                pub fn process(_: *@This(), ev: BusEvent, yield_ctx: ?*anyopaque, yield: YieldFn) void {
                    switch (ev) {
                        .input => |input_ev| {
                            switch (input_ev) {
                                inline else => |val, t| {
                                    log.debugFmt("[bus] input.{s}: {any}", .{ @tagName(t), val });
                                },
                            }
                        },
                        inline else => |val, t| {
                            log.debugFmt("[bus] {s}: {any}", .{ @tagName(t), val });
                        },
                    }
                    yield(yield_ctx, ev);
                }

                pub fn tick(_: *@This(), _: ?*anyopaque, _: YieldFn) void {}
            });
        }

        // --- fields ---

        /// Channel for raw input events from peripherals.
        in_ch: InputChannel,

        /// Channel for processed events after middleware chain.
        out_ch: BusChannel,

        /// Synchronization channel: run() signals completion to stop().
        run_ch: DoneChannel,

        /// Synchronization channel: tick() signals completion to stop().
        tick_ch: DoneChannel,

        /// Allocator for internal resources.
        allocator: std.mem.Allocator,

        /// Registered middleware dispatch slots, invoked in order.
        middlewares: std.ArrayList(MiddlewareSlot),

        /// Whether the bus is active (shared by run and tick loops).
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        /// Whether the tick loop is active.
        ticking: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        // --- pub methods ---

        /// Create a new Bus with the given channel capacity.
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            return .{
                .in_ch = try InputChannel.init(allocator, capacity),
                .out_ch = try BusChannel.init(allocator, capacity),
                .run_ch = try DoneChannel.init(allocator, 1),
                .tick_ch = try DoneChannel.init(allocator, 1),
                .allocator = allocator,
                .middlewares = .empty,
            };
        }

        /// Stop the bus and release all resources.
        pub fn deinit(self: *Self) void {
            self.stop();
            self.middlewares.deinit(self.allocator);
            self.in_ch.deinit();
            self.out_ch.deinit();
            self.run_ch.deinit();
            self.tick_ch.deinit();
        }

        /// Type-safe send: wraps payload into InputEvent and pushes to in_ch.
        pub fn inject(self: *Self, comptime tag: InputEventTag, payload: std.meta.TagPayload(InputEvent, tag)) !SendResult {
            const input_ev = @unionInit(InputEvent, @tagName(tag), payload);
            const r = try self.in_ch.send(input_ev);
            return .{ .ok = r.ok };
        }

        /// Register a middleware into the processing chain.
        /// Only accepts pointers produced by this Bus's Processor/Middleware/Logger.
        pub fn use(self: *Self, mw: anytype) void {
            const Child = comptime blk: {
                const P = @TypeOf(mw);
                const info = @typeInfo(P);
                if (info != .pointer) @compileError("use() expects a pointer to a middleware");
                const C = info.pointer.child;
                if (!@hasDecl(C, "seal") or @TypeOf(C.seal) != MiddlewareSeal)
                    @compileError("use() only accepts middleware created by this Bus's Processor/Middleware/Logger");
                break :blk C;
            };
            self.middlewares.append(self.allocator, .{
                .ctx = @ptrCast(mw),
                .processFn = Child.dispatchFn,
            }) catch {};
        }

        /// Receive the next processed event from out_ch.
        pub fn recv(self: *Self) !RecvResult {
            const r = try self.out_ch.recv();
            return .{ .value = r.value, .ok = r.ok };
        }

        /// Blocking loop: reads in_ch, dispatches through middleware chain, writes to out_ch.
        /// Returns when stop() is called or in_ch closes.
        pub fn run(self: *Self) void {
            self.running.store(true, .release);
            defer {
                self.running.store(false, .release);
                self.out_ch.close();
                _ = self.run_ch.close();
            }

            while (self.running.load(.acquire)) {
                const r = self.in_ch.recv() catch break;
                if (!r.ok) break;

                const bus_ev: BusEvent = .{ .input = r.value };
                self.dispatchChain(bus_ev, 0);
            }
        }

        /// Blocking tick loop: periodically injects `.tick` events into in_ch.
        /// `time` must satisfy the runtime time contract (nowMs, sleepMs).
        /// Returns when stop() is called.
        pub fn tick(self: *Self, time: anytype, interval_ms: u32) void {
            _ = time_mod.is(@TypeOf(time));
            self.ticking.store(true, .release);
            defer {
                self.ticking.store(false, .release);
                _ = self.tick_ch.close();
            }
            while (self.running.load(.acquire)) {
                _ = self.inject(.tick, time.nowMs()) catch break;
                time.sleepMs(interval_ms);
            }
        }

        /// Signal run and tick loops to stop and block until both exit.
        pub fn stop(self: *Self) void {
            if (!self.running.load(.acquire)) return;
            self.running.store(false, .release);
            self.in_ch.close();
            _ = self.run_ch.recv() catch {};
            if (self.ticking.load(.acquire)) {
                _ = self.tick_ch.recv() catch {};
            }
        }

        /// Whether the run loop is currently active.
        pub fn isRunning(self: *const Self) bool {
            return self.running.load(.acquire);
        }

        /// Returns an EventInjector bound to a specific input tag.
        /// Peripherals use this to push typed events into the bus.
        pub fn Injector(self: *Self, comptime tag: InputEventTag) EventInjector(std.meta.TagPayload(InputEvent, tag)) {
            const A = struct {
                fn call(ctx: ?*anyopaque, event: std.meta.TagPayload(InputEvent, tag)) void {
                    const bus: *Self = @ptrCast(@alignCast(ctx orelse return));
                    const input_ev = @unionInit(InputEvent, @tagName(tag), event);
                    _ = bus.in_ch.send(input_ev) catch {};
                }
            };
            return .{ .ctx = @ptrCast(self), .call = A.call };
        }

        // --- private types ---

        const InputChannel = ChannelFactory.Channel(InputEvent);
        const BusChannel = ChannelFactory.Channel(BusEvent);
        const DoneChannel = ChannelFactory.Channel(void);
        const YieldFn = *const fn (ctx: ?*anyopaque, ev: BusEvent) void;
        const ProcessFn = *const fn (ctx: ?*anyopaque, ev: BusEvent, yield_ctx: ?*anyopaque, yield: YieldFn) void;
        const MiddlewareSeal = struct {};
        const MiddlewareSlot = struct {
            ctx: ?*anyopaque,
            processFn: ProcessFn,
        };
        const ChainNext = struct {
            bus: *Self,
            next_idx: usize,
        };

        // --- private methods ---

        fn dispatchChain(self: *Self, ev: BusEvent, adapter_idx: usize) void {
            if (adapter_idx >= self.middlewares.items.len) {
                _ = self.out_ch.send(ev) catch {};
                return;
            }

            const a = self.middlewares.items[adapter_idx];
            const next = ChainNext{ .bus = self, .next_idx = adapter_idx + 1 };
            a.processFn(a.ctx, ev, @ptrCast(@constCast(&next)), chainYield);
        }

        fn chainYield(ctx: ?*anyopaque, ev: BusEvent) void {
            const next: *const ChainNext = @ptrCast(@alignCast(ctx orelse return));
            next.bus.dispatchChain(ev, next.next_idx);
        }
    };
}

fn GenInputType(
    comptime fields: []const std.builtin.Type.StructField,
    comptime spec: anytype,
) type {
    const total = fields.len + 1;
    var union_fields: [total]std.builtin.Type.UnionField = undefined;
    var tag_fields: [total]std.builtin.Type.EnumField = undefined;

    for (fields, 0..) |f, i| {
        const PayloadType: type = @field(spec, f.name);
        union_fields[i] = .{ .name = f.name, .type = PayloadType, .alignment = @alignOf(PayloadType) };
        tag_fields[i] = .{ .name = f.name, .value = i };
    }

    union_fields[fields.len] = .{ .name = "tick", .type = u64, .alignment = @alignOf(u64) };
    tag_fields[fields.len] = .{ .name = "tick", .value = fields.len };

    const TagEnum = @Type(.{ .@"enum" = .{
        .tag_type = std.math.IntFittingRange(0, total - 1),
        .fields = &tag_fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });

    return @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = TagEnum,
        .fields = &union_fields,
        .decls = &.{},
    } });
}

fn BusEventType(
    comptime InputEvent: type,
    comptime output: anytype,
) type {
    const output_info = @typeInfo(@TypeOf(output)).@"struct";
    const total = 1 + output_info.fields.len;

    var union_fields: [total]std.builtin.Type.UnionField = undefined;
    var tag_fields: [total]std.builtin.Type.EnumField = undefined;

    union_fields[0] = .{ .name = "input", .type = InputEvent, .alignment = @alignOf(InputEvent) };
    tag_fields[0] = .{ .name = "input", .value = 0 };

    for (output_info.fields, 0..) |f, i| {
        const PayloadType: type = @field(output, f.name);
        union_fields[1 + i] = .{ .name = f.name, .type = PayloadType, .alignment = @alignOf(PayloadType) };
        tag_fields[1 + i] = .{ .name = f.name, .value = 1 + i };
    }

    const TagEnum = @Type(.{ .@"enum" = .{
        .tag_type = if (total <= 1) u1 else std.math.IntFittingRange(0, total - 1),
        .fields = &tag_fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });

    return @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = TagEnum,
        .fields = &union_fields,
        .decls = &.{},
    } });
}
