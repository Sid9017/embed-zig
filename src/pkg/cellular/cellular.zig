//! Cellular: Flux reducer drives `CellularPhase` + bootstrap step; `tick()` dispatches `ModemEvent`.
//! Phases use *-ing* style names (`probing`, `registering`, `dialing`) for in-flight work.

const types = @import("types.zig");
const modem_mod = @import("modem/modem.zig");
const commands = @import("at/commands.zig");
const bus = @import("../event/bus.zig");
const store_mod = @import("../flux/store.zig");

pub const InitSequenceStep = enum {
    probe,
    ate0,
    cmee,
    cpin,
    cereg,
    done,
};

pub const CellularFsmState = struct {
    modem: types.ModemState = .{},
    bootstrap_step: InitSequenceStep = .done,
};

pub fn cellularReduce(s: *CellularFsmState, e: types.ModemEvent) void {
    switch (e) {
        .power_on => {
            s.modem.phase = .probing;
            s.modem.error_reason = null;
            s.modem.at_timeout_count = 0;
            s.bootstrap_step = .probe;
        },
        .power_off => {
            s.* = .{};
        },
        .bootstrap_probe_ok => {
            if (s.modem.phase == .probing and s.bootstrap_step == .probe) {
                s.modem.phase = .at_configuring;
                s.bootstrap_step = .ate0;
            }
        },
        .bootstrap_echo_ok => {
            if (s.modem.phase == .at_configuring and s.bootstrap_step == .ate0) {
                s.bootstrap_step = .cmee;
            }
        },
        .bootstrap_cmee_ok => {
            if (s.modem.phase == .at_configuring and s.bootstrap_step == .cmee) {
                s.modem.phase = .checking_sim;
                s.bootstrap_step = .cpin;
            }
        },
        .sim_status_reported => |st| {
            s.modem.sim = st;
            switch (st) {
                .ready => {
                    s.modem.phase = .registering;
                    s.bootstrap_step = .cereg;
                },
                .pin_required, .puk_required => {
                    s.modem.phase = .@"error";
                    s.modem.error_reason = .sim_pin_required;
                    s.bootstrap_step = .done;
                },
                .not_inserted => {
                    s.modem.phase = .@"error";
                    s.modem.error_reason = .sim_not_inserted;
                    s.bootstrap_step = .done;
                },
                .@"error" => {
                    s.modem.phase = .@"error";
                    s.modem.error_reason = .sim_error;
                    s.bootstrap_step = .done;
                },
            }
        },
        .network_registration => |reg| {
            s.modem.registration = reg;
            switch (reg) {
                .registered_home, .registered_roaming => {
                    s.modem.phase = .registered;
                    s.bootstrap_step = .done;
                },
                .denied => {
                    s.modem.phase = .@"error";
                    s.modem.error_reason = .registration_denied;
                    s.bootstrap_step = .done;
                },
                else => {
                    s.modem.phase = .registering;
                    s.bootstrap_step = .done;
                },
            }
        },
        .bootstrap_at_error => |reason| {
            s.modem.phase = .@"error";
            s.modem.error_reason = reason;
            s.bootstrap_step = .done;
        },
        .at_timeout => {
            s.modem.at_timeout_count +|= 1;
            s.modem.phase = .@"error";
            s.modem.error_reason = .at_timeout;
            s.bootstrap_step = .done;
        },
        .retry => {
            if (s.modem.phase == .@"error") {
                s.modem.phase = .probing;
                s.modem.error_reason = null;
                s.modem.at_timeout_count = 0;
                s.bootstrap_step = .probe;
            }
        },
        .dial_requested => {
            if (s.modem.phase == .registered) {
                s.modem.phase = .dialing;
            }
        },
        .dial_succeeded => {
            if (s.modem.phase == .dialing) {
                s.modem.phase = .connected;
            }
        },
        .dial_failed => {
            if (s.modem.phase == .dialing) {
                s.modem.phase = .registered;
            }
        },
        .ip_obtained => {
            if (s.modem.phase == .dialing) {
                s.modem.phase = .connected;
            }
        },
        .ip_lost => {
            if (s.modem.phase == .connected) {
                s.modem.phase = .registered;
            }
        },
        .signal_updated => |sig| {
            s.modem.signal = sig;
        },
        .stop => {},
    }
}

pub fn Cellular(
    comptime Thread: type,
    comptime Notify: type,
    comptime Time: type,
    comptime Module: type,
    comptime Gpio: type,
    comptime at_buf_size: usize,
) type {
    const ModemT = modem_mod.Modem(Thread, Notify, Time, Module, Gpio, at_buf_size);
    const Store = store_mod.Store(CellularFsmState, types.ModemEvent);

    return struct {
        const Self = @This();

        modem: ModemT,
        injector: bus.EventInjector(types.CellularPayload),
        store: Store,

        pub fn init(modem_v: ModemT, injector: bus.EventInjector(types.CellularPayload)) Self {
            return .{
                .modem = modem_v,
                .injector = injector,
                .store = Store.init(.{}, cellularReduce),
            };
        }

        fn fsm(self: *const Self) *const CellularFsmState {
            return self.store.getState();
        }

        pub fn phase(self: *const Self) types.CellularPhase {
            return self.fsm().modem.phase;
        }

        pub fn bootstrapStep(self: *const Self) InitSequenceStep {
            return self.fsm().bootstrap_step;
        }

        pub fn modemState(self: *const Self) *const types.ModemState {
            return &self.fsm().modem;
        }

        pub fn applyModemEvents(self: *Self, events: []const types.ModemEvent) void {
            const before = self.fsm().*;
            self.store.dispatchBatch(events);
            self.emitDiff(before, self.fsm().*);
        }

        fn dispatchOne(self: *Self, event: types.ModemEvent) void {
            const before = self.fsm().*;
            self.store.dispatch(event);
            self.emitDiff(before, self.fsm().*);
        }

        fn emitDiff(self: *Self, before: CellularFsmState, after: CellularFsmState) void {
            if (before.modem.phase != after.modem.phase) {
                self.injector.invoke(.{ .phase_changed = .{ .from = before.modem.phase, .to = after.modem.phase } });
            }
            if (before.modem.sim != after.modem.sim) {
                self.injector.invoke(.{ .sim_status_changed = after.modem.sim });
            }
            if (before.modem.registration != after.modem.registration) {
                self.injector.invoke(.{ .registration_changed = after.modem.registration });
            }
            if (before.modem.error_reason != after.modem.error_reason) {
                if (after.modem.error_reason) |r| {
                    self.injector.invoke(.{ .@"error" = r });
                }
            }
        }

        pub fn powerOn(self: *Self) void {
            self.dispatchOne(.power_on);
        }

        pub fn powerOff(self: *Self) void {
            const before = self.fsm().*;
            self.store.dispatch(.power_off);
            self.emitDiff(before, self.fsm().*);
        }

        pub fn tick(self: *Self) void {
            const m = self.fsm().modem;
            const step = self.fsm().bootstrap_step;
            switch (m.phase) {
                .off => {},
                .probing => if (step == .probe) {
                    self.runProbe();
                },
                .at_configuring => switch (step) {
                    .ate0 => self.runAte0(),
                    .cmee => self.runCmee(),
                    else => {},
                },
                .checking_sim => if (step == .cpin) {
                    self.runCpin();
                },
                .registering => self.sendCeregQuery(),
                .registered,
                .dialing,
                .connected,
                .disconnecting,
                .@"error",
                => {},
            }
        }

        fn runProbe(self: *Self) void {
            const out = self.modem.at().send(commands.Probe, {});
            if (out.status != .ok) {
                self.dispatchOne(.{ .bootstrap_at_error = if (out.status == .timeout) .at_timeout else .at_fatal });
                return;
            }
            self.dispatchOne(.bootstrap_probe_ok);
        }

        fn runAte0(self: *Self) void {
            const out = self.modem.at().send(commands.SetEchoOff, {});
            if (out.status != .ok) {
                self.dispatchOne(.{ .bootstrap_at_error = if (out.status == .timeout) .at_timeout else .at_fatal });
                return;
            }
            self.dispatchOne(.bootstrap_echo_ok);
        }

        fn runCmee(self: *Self) void {
            const out = self.modem.at().send(commands.SetCmeErrorVerbose, {});
            if (out.status != .ok) {
                self.dispatchOne(.{ .bootstrap_at_error = if (out.status == .timeout) .at_timeout else .at_fatal });
                return;
            }
            self.dispatchOne(.bootstrap_cmee_ok);
        }

        fn runCpin(self: *Self) void {
            const out = self.modem.at().send(commands.GetCpin, {});
            if (out.status != .ok) {
                self.dispatchOne(.{ .bootstrap_at_error = if (out.status == .timeout) .at_timeout else .at_fatal });
                return;
            }
            const st = out.value orelse {
                self.dispatchOne(.{ .bootstrap_at_error = .at_fatal });
                return;
            };
            self.dispatchOne(.{ .sim_status_reported = st });
        }

        fn sendCeregQuery(self: *Self) void {
            const out = self.modem.at().send(commands.GetCereg, {});
            if (out.status != .ok) {
                self.dispatchOne(.{ .bootstrap_at_error = if (out.status == .timeout) .at_timeout else .at_fatal });
                return;
            }
            const reg = out.value orelse {
                self.dispatchOne(.{ .bootstrap_at_error = .at_fatal });
                return;
            };
            self.dispatchOne(.{ .network_registration = reg });
        }
    };
}
