//! Unit tests for pkg/cellular/types.zig. One test per type/field contract; mirrors pkg/event/types_test.zig style.

const std = @import("std");
const embed = @import("embed");
const types = embed.pkg.cellular.types;

// =============================================================================
// Enums: each tag constructible and equality
// =============================================================================

test "CellularPhase: all variants and default-like value" {
    try std.testing.expectEqual(types.CellularPhase.off, .off);
    try std.testing.expectEqual(types.CellularPhase.starting, .starting);
    try std.testing.expectEqual(types.CellularPhase.ready, .ready);
    try std.testing.expectEqual(types.CellularPhase.sim_ready, .sim_ready);
    try std.testing.expectEqual(types.CellularPhase.registered, .registered);
    try std.testing.expectEqual(types.CellularPhase.dialing, .dialing);
    try std.testing.expectEqual(types.CellularPhase.connected, .connected);
    try std.testing.expectEqual(types.CellularPhase.@"error", .@"error");
}

test "SimStatus: all variants" {
    try std.testing.expectEqual(types.SimStatus.not_inserted, .not_inserted);
    try std.testing.expectEqual(types.SimStatus.pin_required, .pin_required);
    try std.testing.expectEqual(types.SimStatus.puk_required, .puk_required);
    try std.testing.expectEqual(types.SimStatus.ready, .ready);
    try std.testing.expectEqual(types.SimStatus.@"error", .@"error");
}

test "RAT: all variants" {
    try std.testing.expectEqual(types.RAT.none, .none);
    try std.testing.expectEqual(types.RAT.gsm, .gsm);
    try std.testing.expectEqual(types.RAT.gprs, .gprs);
    try std.testing.expectEqual(types.RAT.edge, .edge);
    try std.testing.expectEqual(types.RAT.umts, .umts);
    try std.testing.expectEqual(types.RAT.hsdpa, .hsdpa);
    try std.testing.expectEqual(types.RAT.lte, .lte);
}

test "CellularRegStatus: all variants" {
    try std.testing.expectEqual(types.CellularRegStatus.not_registered, .not_registered);
    try std.testing.expectEqual(types.CellularRegStatus.registered_home, .registered_home);
    try std.testing.expectEqual(types.CellularRegStatus.searching, .searching);
    try std.testing.expectEqual(types.CellularRegStatus.denied, .denied);
    try std.testing.expectEqual(types.CellularRegStatus.registered_roaming, .registered_roaming);
    try std.testing.expectEqual(types.CellularRegStatus.unknown, .unknown);
}

test "VoiceCallState: all variants" {
    try std.testing.expectEqual(types.VoiceCallState.idle, .idle);
    try std.testing.expectEqual(types.VoiceCallState.incoming, .incoming);
    try std.testing.expectEqual(types.VoiceCallState.dialing, .dialing);
    try std.testing.expectEqual(types.VoiceCallState.alerting, .alerting);
    try std.testing.expectEqual(types.VoiceCallState.active, .active);
}

test "ModemError: all variants" {
    try std.testing.expectEqual(types.ModemError.at_timeout, .at_timeout);
    try std.testing.expectEqual(types.ModemError.at_fatal, .at_fatal);
    try std.testing.expectEqual(types.ModemError.sim_not_inserted, .sim_not_inserted);
    try std.testing.expectEqual(types.ModemError.sim_pin_required, .sim_pin_required);
    try std.testing.expectEqual(types.ModemError.sim_error, .sim_error);
    try std.testing.expectEqual(types.ModemError.cmux_failed, .cmux_failed);
    try std.testing.expectEqual(types.ModemError.registration_denied, .registration_denied);
    try std.testing.expectEqual(types.ModemError.registration_failed, .registration_failed);
    try std.testing.expectEqual(types.ModemError.ppp_failed, .ppp_failed);
    try std.testing.expectEqual(types.ModemError.config_failed, .config_failed);
}

test "CmuxChannelRole: at and ppp" {
    try std.testing.expectEqual(types.CmuxChannelRole.at, .at);
    try std.testing.expectEqual(types.CmuxChannelRole.ppp, .ppp);
}

// =============================================================================
// CellularSignalInfo: rssi required; ber, rsrp, rsrq optional
// =============================================================================

test "CellularSignalInfo: default optional fields are null" {
    const s = types.CellularSignalInfo{ .rssi = -75 };
    try std.testing.expectEqual(@as(i8, -75), s.rssi);
    try std.testing.expect(s.ber == null);
    try std.testing.expect(s.rsrp == null);
    try std.testing.expect(s.rsrq == null);
}

test "CellularSignalInfo: all optionals set" {
    const s = types.CellularSignalInfo{
        .rssi = -80,
        .ber = 0,
        .rsrp = -100,
        .rsrq = -10,
    };
    try std.testing.expectEqual(@as(i8, -80), s.rssi);
    try std.testing.expectEqual(@as(u8, 0), s.ber.?);
    try std.testing.expectEqual(@as(i16, -100), s.rsrp.?);
    try std.testing.expectEqual(@as(i8, -10), s.rsrq.?);
}

// =============================================================================
// ModemInfo: buffers + len; getters return correct slice
// =============================================================================

test "ModemInfo: default lengths zero and getters return empty slice" {
    const info: types.ModemInfo = .{};
    try std.testing.expectEqual(@as(u8, 0), info.imei_len);
    try std.testing.expectEqual(@as(u8, 0), info.model_len);
    try std.testing.expectEqual(@as(u8, 0), info.firmware_len);
    try std.testing.expectEqualStrings("", info.getImei());
    try std.testing.expectEqualStrings("", info.getModel());
    try std.testing.expectEqualStrings("", info.getFirmware());
}

test "ModemInfo: full IMEI 15 bytes and getter" {
    var info: types.ModemInfo = .{};
    const imei = "123456789012345";
    @memcpy(info.imei[0..imei.len], imei);
    info.imei_len = 15;
    try std.testing.expectEqual(@as(u8, 15), info.imei_len);
    try std.testing.expectEqualStrings(imei, info.getImei());
}

test "ModemInfo: partial model and getter" {
    var info: types.ModemInfo = .{};
    const model = "EC25";
    @memcpy(info.model[0..model.len], model);
    info.model_len = 4;
    try std.testing.expectEqualStrings(model, info.getModel());
}

test "ModemInfo: firmware and all three getters together" {
    var info: types.ModemInfo = .{};
    const imei = "123456789012345";
    const model = "EC25";
    const firmware = "1.0.0";
    @memcpy(info.imei[0..imei.len], imei);
    info.imei_len = @intCast(imei.len);
    @memcpy(info.model[0..model.len], model);
    info.model_len = @intCast(model.len);
    @memcpy(info.firmware[0..firmware.len], firmware);
    info.firmware_len = @intCast(firmware.len);
    try std.testing.expectEqualStrings(imei, info.getImei());
    try std.testing.expectEqualStrings(model, info.getModel());
    try std.testing.expectEqualStrings(firmware, info.getFirmware());
}

// =============================================================================
// SimInfo: status + IMSI/ICCID buffers and getters
// =============================================================================

test "SimInfo: default status and empty getters" {
    const sim: types.SimInfo = .{};
    try std.testing.expectEqual(types.SimStatus.not_inserted, sim.status);
    try std.testing.expectEqual(@as(u8, 0), sim.imsi_len);
    try std.testing.expectEqual(@as(u8, 0), sim.iccid_len);
    try std.testing.expectEqualStrings("", sim.getImsi());
    try std.testing.expectEqualStrings("", sim.getIccid());
}

test "SimInfo: status and full IMSI/ICCID" {
    var sim: types.SimInfo = .{};
    sim.status = .ready;
    const imsi = "123456789012345";
    const iccid = "12345678901234567890";
    @memcpy(sim.imsi[0..imsi.len], imsi);
    sim.imsi_len = @intCast(imsi.len);
    @memcpy(sim.iccid[0..iccid.len], iccid);
    sim.iccid_len = @intCast(iccid.len);
    try std.testing.expectEqual(types.SimStatus.ready, sim.status);
    try std.testing.expectEqualStrings(imsi, sim.getImsi());
    try std.testing.expectEqualStrings(iccid, sim.getIccid());
}

test "SimInfo: partial ICCID" {
    var sim: types.SimInfo = .{};
    const iccid = "8901234567";
    @memcpy(sim.iccid[0..iccid.len], iccid);
    sim.iccid_len = 10;
    try std.testing.expectEqualStrings(iccid, sim.getIccid());
}

// =============================================================================
// ModemState: every field default then explicit
// =============================================================================

test "ModemState: all fields default" {
    const state: types.ModemState = .{};
    try std.testing.expectEqual(types.CellularPhase.off, state.phase);
    try std.testing.expectEqual(types.SimStatus.not_inserted, state.sim);
    try std.testing.expectEqual(types.CellularRegStatus.not_registered, state.registration);
    try std.testing.expectEqual(types.RAT.none, state.network_type);
    try std.testing.expect(state.signal == null);
    try std.testing.expect(state.modem_info == null);
    try std.testing.expect(state.sim_info == null);
    try std.testing.expect(state.error_reason == null);
    try std.testing.expectEqual(@as(u8, 0), state.at_timeout_count);
}

test "ModemState: all fields set explicitly" {
    const sig = types.CellularSignalInfo{ .rssi = -70 };
    var modem_info: types.ModemInfo = .{};
    modem_info.model_len = 4;
    @memcpy(modem_info.model[0..4], "EC25");
    var sim_info: types.SimInfo = .{};
    sim_info.status = .ready;

    const state = types.ModemState{
        .phase = .registered,
        .sim = .ready,
        .registration = .registered_home,
        .network_type = .lte,
        .signal = sig,
        .modem_info = modem_info,
        .sim_info = sim_info,
        .error_reason = null,
        .at_timeout_count = 2,
    };
    try std.testing.expectEqual(types.CellularPhase.registered, state.phase);
    try std.testing.expectEqual(types.SimStatus.ready, state.sim);
    try std.testing.expectEqual(types.CellularRegStatus.registered_home, state.registration);
    try std.testing.expectEqual(types.RAT.lte, state.network_type);
    try std.testing.expect(state.signal != null);
    try std.testing.expectEqual(@as(i8, -70), state.signal.?.rssi);
    try std.testing.expect(state.modem_info != null);
    try std.testing.expect(state.sim_info != null);
    try std.testing.expectEqual(@as(u8, 2), state.at_timeout_count);
}

test "ModemState: error_reason set when phase error" {
    const state = types.ModemState{
        .phase = .@"error",
        .error_reason = .at_timeout,
    };
    try std.testing.expectEqual(types.CellularPhase.@"error", state.phase);
    try std.testing.expectEqual(types.ModemError.at_timeout, state.error_reason.?);
}

// =============================================================================
// ModemEvent: each union tag and payload
// =============================================================================

test "ModemEvent: void payloads" {
    _ = types.ModemEvent{ .power_on = {} };
    _ = types.ModemEvent{ .power_off = {} };
    _ = types.ModemEvent{ .at_ready = {} };
    _ = types.ModemEvent{ .at_timeout = {} };
    _ = types.ModemEvent{ .sim_ready = {} };
    _ = types.ModemEvent{ .sim_removed = {} };
    _ = types.ModemEvent{ .pin_required = {} };
    _ = types.ModemEvent{ .dial_start = {} };
    _ = types.ModemEvent{ .dial_connected = {} };
    _ = types.ModemEvent{ .dial_failed = {} };
    _ = types.ModemEvent{ .ip_obtained = {} };
    _ = types.ModemEvent{ .ip_lost = {} };
    _ = types.ModemEvent{ .retry = {} };
    _ = types.ModemEvent{ .stop = {} };
}

test "ModemEvent: sim_error with SimStatus" {
    const ev = types.ModemEvent{ .sim_error = .pin_required };
    try std.testing.expectEqual(types.SimStatus.pin_required, ev.sim_error);
}

test "ModemEvent: registered and registration_failed with CellularRegStatus" {
    const ev1 = types.ModemEvent{ .registered = .registered_home };
    try std.testing.expectEqual(types.CellularRegStatus.registered_home, ev1.registered);
    const ev2 = types.ModemEvent{ .registration_failed = .denied };
    try std.testing.expectEqual(types.CellularRegStatus.denied, ev2.registration_failed);
}

test "ModemEvent: signal_updated with CellularSignalInfo" {
    const sig = types.CellularSignalInfo{ .rssi = -65, .ber = 1 };
    const ev = types.ModemEvent{ .signal_updated = sig };
    try std.testing.expectEqual(@as(i8, -65), ev.signal_updated.rssi);
    try std.testing.expectEqual(@as(u8, 1), ev.signal_updated.ber.?);
}

// =============================================================================
// BaudRate and default_at_timeout_ms
// =============================================================================

test "BaudRate: standard values" {
    try std.testing.expectEqual(@as(u32, 9600), types.BaudRate.b9600);
    try std.testing.expectEqual(@as(u32, 115200), types.BaudRate.b115200);
    try std.testing.expectEqual(@as(u32, 921600), types.BaudRate.b921600);
}

test "default_at_timeout_ms" {
    try std.testing.expectEqual(@as(u32, 5000), types.default_at_timeout_ms);
}

test "BufferLen: IMEI/IMSI/ICCID/model/firmware sizes" {
    try std.testing.expectEqual(15, types.BufferLen.imei);
    try std.testing.expectEqual(15, types.BufferLen.imsi);
    try std.testing.expectEqual(20, types.BufferLen.iccid);
    try std.testing.expectEqual(32, types.BufferLen.model);
    try std.testing.expectEqual(32, types.BufferLen.firmware);
}

// =============================================================================
// APNConfig
// =============================================================================

test "APNConfig: apn required, username and password default empty" {
    const cfg = types.APNConfig{ .apn = "internet" };
    try std.testing.expectEqualStrings("internet", cfg.apn);
    try std.testing.expectEqualStrings("", cfg.username);
    try std.testing.expectEqualStrings("", cfg.password);
}

test "APNConfig: all three set" {
    const cfg = types.APNConfig{
        .apn = "cmnet",
        .username = "user",
        .password = "pass",
    };
    try std.testing.expectEqualStrings("cmnet", cfg.apn);
    try std.testing.expectEqualStrings("user", cfg.username);
    try std.testing.expectEqualStrings("pass", cfg.password);
}

// =============================================================================
// CmuxChannelConfig
// =============================================================================

test "CmuxChannelConfig: dlci and role" {
    const c1 = types.CmuxChannelConfig{ .dlci = 1, .role = .ppp };
    try std.testing.expectEqual(@as(u8, 1), c1.dlci);
    try std.testing.expectEqual(types.CmuxChannelRole.ppp, c1.role);

    const c2 = types.CmuxChannelConfig{ .dlci = 2, .role = .at };
    try std.testing.expectEqual(@as(u8, 2), c2.dlci);
    try std.testing.expectEqual(types.CmuxChannelRole.at, c2.role);
}

// =============================================================================
// ModemConfig: defaults and each field
// =============================================================================

test "ModemConfig: default cmux_channels and numeric fields" {
    const cfg: types.ModemConfig = .{};
    try std.testing.expect(cfg.cmux_channels.len == 2);
    try std.testing.expectEqual(@as(u8, 1), cfg.cmux_channels[0].dlci);
    try std.testing.expectEqual(types.CmuxChannelRole.ppp, cfg.cmux_channels[0].role);
    try std.testing.expectEqual(@as(u8, 2), cfg.cmux_channels[1].dlci);
    try std.testing.expectEqual(types.CmuxChannelRole.at, cfg.cmux_channels[1].role);
    try std.testing.expectEqual(types.BaudRate.b921600, cfg.cmux_baud_rate);
    try std.testing.expectEqual(types.default_at_timeout_ms, cfg.at_timeout_ms);
    try std.testing.expectEqual(@as(u8, 16), cfg.max_urc_handlers);
    try std.testing.expectEqual(@as(u8, 1), cfg.context_id);
}

test "ModemConfig: explicit values" {
    const ch = [_]types.CmuxChannelConfig{
        .{ .dlci = 3, .role = .at },
        .{ .dlci = 4, .role = .ppp },
    };
    const cfg = types.ModemConfig{
        .cmux_channels = &ch,
        .cmux_baud_rate = types.BaudRate.b115200,
        .at_timeout_ms = 3000,
        .max_urc_handlers = 8,
        .context_id = 2,
    };
    try std.testing.expectEqual(@as(usize, 2), cfg.cmux_channels.len);
    try std.testing.expectEqual(@as(u8, 3), cfg.cmux_channels[0].dlci);
    try std.testing.expectEqual(types.BaudRate.b115200, cfg.cmux_baud_rate);
    try std.testing.expectEqual(@as(u32, 3000), cfg.at_timeout_ms);
    try std.testing.expectEqual(@as(u8, 8), cfg.max_urc_handlers);
    try std.testing.expectEqual(@as(u8, 2), cfg.context_id);
}

// =============================================================================
// CellularPayload: each tag and payload
// =============================================================================

test "CellularPayload: phase_changed" {
    const p = types.CellularPayload{
        .phase_changed = .{ .from = .off, .to = .registered },
    };
    try std.testing.expectEqual(types.CellularPhase.off, p.phase_changed.from);
    try std.testing.expectEqual(types.CellularPhase.registered, p.phase_changed.to);
}

test "CellularPayload: signal_updated" {
    const sig = types.CellularSignalInfo{ .rssi = -72 };
    const p = types.CellularPayload{ .signal_updated = sig };
    try std.testing.expectEqual(@as(i8, -72), p.signal_updated.rssi);
}

test "CellularPayload: sim_status_changed" {
    const p = types.CellularPayload{ .sim_status_changed = .ready };
    try std.testing.expectEqual(types.SimStatus.ready, p.sim_status_changed);
}

test "CellularPayload: registration_changed" {
    const p = types.CellularPayload{ .registration_changed = .registered_roaming };
    try std.testing.expectEqual(types.CellularRegStatus.registered_roaming, p.registration_changed);
}

test "CellularPayload: error" {
    const p = types.CellularPayload{ .@"error" = .cmux_failed };
    try std.testing.expectEqual(types.ModemError.cmux_failed, p.@"error");
}
