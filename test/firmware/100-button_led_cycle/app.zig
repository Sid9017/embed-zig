//! 100-button_led_cycle — Button-driven LED color cycling via Bus.
//!
//! Demonstrates the full event pipeline:
//!   GpioButton → Bus(in_ch) → GestureProcessor → Logger → out_ch → reduce
//!
//! Behavior:
//!   - 1 click:  → red (fade)
//!   - 2 clicks: → green (fade)
//!   - 3 clicks: → blue (fade)
//!   - 4 clicks: → white (fade)
//!   - Long press: → toggle off / white (fade)

const embed = @import("embed");
const runtime = embed.runtime;
const event = embed.pkg.event;
const button = event.button;

const App = @import("state.zig");

pub fn run(comptime hw: type, env: anytype) void {
    _ = env;

    const board_spec = @import("board_spec.zig");
    const Board = board_spec.Board(hw);

    const Gpio = Board.gpio;
    const Time = Board.time;
    const Thread = Board.thread.Type;

    const EventBus = event.Bus(.{
        .btn_boot = button.RawEvent,
    }, .{
        .gesture = button.GestureEvent,
    }, Board.channel);

    const GpioButton = event.button.GpioButton(Gpio, Time, "btn_boot");
    const Gesture = button.ButtonGesture(Time, .{
        .long_press_ms = 500,
        .multi_click_window_ms = 300,
    });

    const log: Board.log = .{};
    const allocator = Board.allocator.system;

    var board: Board = undefined;
    board.init() catch {
        log.err("board init failed");
        return;
    };
    defer board.deinit();

    var bus = EventBus.init(allocator, 16) catch {
        log.err("bus init failed");
        return;
    };
    defer bus.deinit();

    var btn = GpioButton.init(&board.gpio_dev, Time{}, .{
        .pin = hw.button_pin,
        .active_level = .low,
    }, bus.Injector(.btn_boot));
    _ = &btn;

    const gesture_mw = EventBus.Processor(.btn_boot, .gesture, Gesture).init(allocator) catch {
        log.err("gesture middleware init failed");
        return;
    };
    defer gesture_mw.deinit();
    bus.use(gesture_mw);

    const log_mw = EventBus.Logger(Board.log).init(allocator) catch {
        log.err("logger middleware init failed");
        return;
    };
    defer log_mw.deinit();
    bus.use(log_mw);

    const Runners = struct {
        fn runBtn(ctx: ?*anyopaque) void {
            const b: *@TypeOf(btn) = @ptrCast(@alignCast(ctx orelse return));
            b.run();
        }
        fn runBus(ctx: ?*anyopaque) void {
            const b: *EventBus = @ptrCast(@alignCast(ctx orelse return));
            b.run();
        }
        fn runTick(ctx: ?*anyopaque) void {
            const b: *EventBus = @ptrCast(@alignCast(ctx orelse return));
            const t: Time = .{};
            b.tick(t, 20);
        }
    };

    var btn_thread = Thread.spawn(Board.thread.user, Runners.runBtn, @ptrCast(&btn)) catch {
        log.err("button worker start failed");
        return;
    };

    var bus_thread = Thread.spawn(Board.thread.system, Runners.runBus, @ptrCast(&bus)) catch {
        log.err("bus run thread start failed");
        return;
    };

    var tick_thread = Thread.spawn(Board.thread.system, Runners.runTick, @ptrCast(&bus)) catch {
        log.err("tick thread start failed");
        return;
    };

    log.info("100-button_led_cycle started");

    var state = App.State{};

    while (Board.isRunning()) {
        const r = bus.recv() catch break;
        if (!r.ok) break;

        switch (r.value) {
            .gesture => |gesture_ev| App.reduce(&state, gesture_ev),
            .input => |input_ev| {
                switch (input_ev) {
                    .tick => _ = state.led.tick(),
                    else => {},
                }
            },
        }

        board.led_strip_dev.setPixels(&state.led.current.pixels);
    }

    bus.stop();
    btn.stop();
    btn_thread.join();
    bus_thread.join();
    tick_thread.join();

    log.info("100-button_led_cycle stopped");
}
