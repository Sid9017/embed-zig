//! Integration tests: `Modem` wires `MockIo` into `AtEngine` (`modem.at()`).

const std = @import("std");
const embed = @import("embed");
const modem_mod = embed.pkg.cellular.modem.modem_mod;
const mock_mod = embed.pkg.cellular.io.mock;
const commands = embed.pkg.cellular.at.commands;
const engine = embed.pkg.cellular.at.engine;

const FakeTime = struct {
    ms: *u64,
    pub fn nowMs(self: FakeTime) u64 {
        return self.ms.*;
    }
    pub fn sleepMs(self: FakeTime, delta: u32) void {
        self.ms.* +%= delta;
    }
};

/// Placeholder until Modem wires a real `hal.gpio` handle in tests.
const GpioPlaceholder = struct {};

fn ModemUnderTest() type {
    return modem_mod.Modem(
        struct {},
        struct {},
        FakeTime,
        embed.pkg.cellular.modem.profiles.quectel,
        GpioPlaceholder,
        512,
    );
}

test "modem.at sendRaw over MockIo: command written, OK parsed" {
    var mock = mock_mod.MockIo.init();
    mock.feed("OK\r\n");
    var ms: u64 = 0;

    var m = ModemUnderTest().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });

    const r = m.at().sendRaw("AT\r\n", 10_000);
    try std.testing.expectEqual(engine.AtStatus.ok, r.status);
    try std.testing.expectEqualStrings("AT\r\n", mock.sent());
}

test "modem.at send(Probe): typed path uses same Io" {
    var mock = mock_mod.MockIo.init();
    mock.feed("OK\r\n");
    var ms: u64 = 0;

    var m = ModemUnderTest().init(.{
        .at_io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });

    const out = m.at().send(commands.Probe, {});
    try std.testing.expectEqual(engine.AtStatus.ok, out.status);
    try std.testing.expectEqualStrings("AT\r\n", mock.sent());
}

test "modem.at sendRaw: CME ERROR propagated" {
    var mock = mock_mod.MockIo.init();
    mock.feed("\r\n+CME ERROR: 123\r\n");
    var ms: u64 = 0;

    var m = ModemUnderTest().init(.{
        .io = mock.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });

    const r = m.at().sendRaw("AT\r\n", 10_000);
    try std.testing.expectEqual(engine.AtStatus.cme_error, r.status);
    try std.testing.expectEqual(@as(u16, 123), r.error_code.?);
}

test "modem init prefers at_io over io" {
    var mock_at = mock_mod.MockIo.init();
    var mock_data = mock_mod.MockIo.init();
    mock_at.feed("OK\r\n");
    var ms: u64 = 0;

    var m = ModemUnderTest().init(.{
        .io = mock_data.io(),
        .at_io = mock_at.io(),
        .time = .{ .ms = &ms },
        .gpio = null,
    });

    _ = m.at().sendRaw("AT\r\n", 10_000);
    try std.testing.expectEqualStrings("AT\r\n", mock_at.sent());
    try std.testing.expectEqual(@as(usize, 0), mock_data.sent().len);
}
