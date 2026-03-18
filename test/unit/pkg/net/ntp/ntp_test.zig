const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const Ntp = embed.pkg.net.ntp;
const Std = embed.runtime.std;

fn nowMs() i64 {
    return @intCast(Std.Time.nowMs(.{}));
}

test "NTP timestamp conversion" {
    // Test round-trip conversion
    const test_ms: i64 = 1706000000000; // 2024-01-23 roughly
    const ntp = Ntp.unixMsToNtp(test_ms);
    const back = Ntp.ntpToUnixMs(ntp);

    // Should be within 1ms due to fraction precision
    try std.testing.expect(@abs(back - test_ms) <= 1);
}

test "NTP request packet format" {
    var buf: [48]u8 = undefined;
    Ntp.buildRequest(&buf, 0);

    // Check LI|VN|Mode byte
    try std.testing.expectEqual(@as(u8, 0x23), buf[0]);
    // Check poll interval
    try std.testing.expectEqual(@as(u8, 6), buf[2]);
}

test "formatTime" {
    // 2024-01-23 12:14:56 UTC (Unix timestamp: 1706012096)
    const epoch_ms: i64 = 1706012096000;
    var buf: [32]u8 = undefined;
    const formatted = Ntp.formatTime(epoch_ms, &buf);

    try std.testing.expect(formatted.len > 0);
    try std.testing.expectEqualStrings("2024-01-23T12:14:56Z", formatted);
}

test "generateNonce produces non-zero values" {
    const nonce = Ntp.generateNonce(Std);
    try std.testing.expect(nonce != 0);

    const nonce2 = Ntp.generateNonce(Std);
    try std.testing.expect(nonce2 != 0);
}

test "query Aliyun NTP server" {
    const NtpClient = Ntp.Client(Std);
    const client = NtpClient{ .server = Ntp.Servers.aliyun, .timeout_ms = 5000 };

    const t1 = nowMs();
    const resp = try client.query(t1);
    const t4 = nowMs();

    try std.testing.expect(resp.stratum >= 1 and resp.stratum <= 15);
    try std.testing.expect(resp.transmit_time_ms > 1_700_000_000_000);
    try std.testing.expect(resp.receive_time_ms > 1_700_000_000_000);

    const offset = @divFloor(
        (resp.receive_time_ms - t1) + (resp.transmit_time_ms - @as(i64, t4)),
        2,
    );
    try std.testing.expect(@abs(offset) < 60_000);
}

test "query Cloudflare NTP server" {
    const NtpClient = Ntp.Client(Std);
    const client = NtpClient{ .server = Ntp.Servers.cloudflare, .timeout_ms = 5000 };

    const t1 = nowMs();
    const resp = try client.query(t1);

    try std.testing.expect(resp.stratum >= 1 and resp.stratum <= 15);
    try std.testing.expect(resp.transmit_time_ms > 1_700_000_000_000);
}

test "getTime returns reasonable epoch" {
    const NtpClient = Ntp.Client(Std);
    const client = NtpClient{ .server = Ntp.Servers.aliyun, .timeout_ms = 5000 };

    const time_ms = try client.getTime(nowMs());
    try std.testing.expect(time_ms > 1_700_000_000_000);

    const local = nowMs();
    try std.testing.expect(@abs(time_ms - local) < 60_000);
}

test "queryRace with multiple servers" {
    const NtpClient = Ntp.Client(Std);
    const client = NtpClient{ .timeout_ms = 5000 };

    const servers = [_]Ntp.Ipv4Address{ Ntp.Servers.aliyun, Ntp.Servers.cloudflare, Ntp.Servers.google };
    const t1 = nowMs();
    const resp = try client.queryRace(t1, &servers);

    try std.testing.expect(resp.stratum >= 1 and resp.stratum <= 15);
    try std.testing.expect(resp.transmit_time_ms > 1_700_000_000_000);
}

test "getTimeRace returns reasonable epoch" {
    const NtpClient = Ntp.Client(Std);
    const client = NtpClient{ .timeout_ms = 5000 };

    const time_ms = try client.getTimeRace(nowMs());
    try std.testing.expect(time_ms > 1_700_000_000_000);

    const local = nowMs();
    try std.testing.expect(@abs(time_ms - local) < 60_000);
}

test "two queries return consistent times" {
    const NtpClient = Ntp.Client(Std);
    const client = NtpClient{ .server = Ntp.Servers.aliyun, .timeout_ms = 5000 };

    const t1 = try client.getTime(nowMs());
    const t2 = try client.getTime(nowMs());

    try std.testing.expect(@abs(t2 - t1) < 5_000);
}

test "formatTime on NTP result" {
    const NtpClient = Ntp.Client(Std);
    const client = NtpClient{ .server = Ntp.Servers.aliyun, .timeout_ms = 5000 };

    const time_ms = try client.getTime(nowMs());
    var buf: [32]u8 = undefined;
    const formatted = Ntp.formatTime(time_ms, &buf);

    try std.testing.expect(formatted.len == 20);
    try std.testing.expect(formatted[4] == '-');
    try std.testing.expect(formatted[7] == '-');
    try std.testing.expect(formatted[10] == 'T');
    try std.testing.expect(formatted[19] == 'Z');
    try std.testing.expect(formatted[0] == '2');
}

test "query Google NTP server" {
    const NtpClient = Ntp.Client(Std);
    const client = NtpClient{ .server = Ntp.Servers.google, .timeout_ms = 8000 };

    const resp = client.query(nowMs()) catch |err| switch (err) {
        error.Timeout => return,
        else => return err,
    };
    try std.testing.expect(resp.stratum >= 1 and resp.stratum <= 15);
    try std.testing.expect(resp.transmit_time_ms > 1_700_000_000_000);
}

test "query with offset calculation" {
    const NtpClient = Ntp.Client(Std);
    const client = NtpClient{ .server = Ntp.Servers.aliyun, .timeout_ms = 5000 };

    const t1 = nowMs();
    const resp = try client.query(t1);
    const t4 = nowMs();

    const offset = @divFloor(
        (resp.receive_time_ms - t1) + (resp.transmit_time_ms - @as(i64, t4)),
        2,
    );
    const rtt = (t4 - t1) - (resp.transmit_time_ms - resp.receive_time_ms);

    try std.testing.expect(@abs(offset) < 60_000);
    try std.testing.expect(rtt >= 0 and rtt < 10_000);
}

test "queryRace with china server list" {
    const NtpClient = Ntp.Client(Std);
    const client = NtpClient{ .timeout_ms = 5000 };

    const resp = try client.queryRace(nowMs(), &Ntp.ServerLists.china);
    try std.testing.expect(resp.stratum >= 1 and resp.stratum <= 15);
    try std.testing.expect(resp.transmit_time_ms > 1_700_000_000_000);
}

test "queryRace with overseas server list" {
    const NtpClient = Ntp.Client(Std);
    const client = NtpClient{ .timeout_ms = 8000 };

    const resp = client.queryRace(nowMs(), &Ntp.ServerLists.overseas) catch |err| switch (err) {
        error.Timeout => return,
        else => return err,
    };
    try std.testing.expect(resp.stratum >= 1 and resp.stratum <= 15);
    try std.testing.expect(resp.transmit_time_ms > 1_700_000_000_000);
}

test "Servers constants are valid" {
    try std.testing.expectEqual(Ntp.Ipv4Address{ 162, 159, 200, 1 }, Ntp.Servers.cloudflare);
    try std.testing.expectEqual(Ntp.Ipv4Address{ 216, 239, 35, 0 }, Ntp.Servers.google);
    try std.testing.expectEqual(Ntp.Ipv4Address{ 203, 107, 6, 88 }, Ntp.Servers.aliyun);
    try std.testing.expectEqual(Ntp.Ipv4Address{ 111, 230, 189, 174 }, Ntp.Servers.tencent);
}

test "ServerLists have entries" {
    try std.testing.expect(Ntp.ServerLists.global.len >= 2);
    try std.testing.expect(Ntp.ServerLists.china.len >= 3);
    try std.testing.expect(Ntp.ServerLists.overseas.len >= 3);
}

test "NTP_UNIX_OFFSET is correct" {
    try std.testing.expectEqual(@as(i64, 2208988800), Ntp.NTP_UNIX_OFFSET);
}

test "NTP_PORT is 123" {
    try std.testing.expectEqual(@as(u16, 123), Ntp.NTP_PORT);
}

test "formatTime negative epoch" {
    var buf: [32]u8 = undefined;
    const s = Ntp.formatTime(-1000, &buf);
    try std.testing.expectEqualStrings("????-??-??T??:??:??Z", s);
}

test "formatTime epoch zero" {
    var buf: [32]u8 = undefined;
    const s = Ntp.formatTime(0, &buf);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", s);
}

test "buildRequest with non-zero origin has transmit timestamp" {
    var buf: [48]u8 = undefined;
    Ntp.buildRequest(&buf, 1706012096000);
    var has_nonzero = false;
    for (buf[40..48]) |b| {
        if (b != 0) {
            has_nonzero = true;
            break;
        }
    }
    try std.testing.expect(has_nonzero);
}

test "buildRequest with zero origin has zero transmit timestamp" {
    var buf: [48]u8 = undefined;
    Ntp.buildRequest(&buf, 0);
    for (buf[40..48]) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
}

test "concurrent NTP queries from multiple threads" {
    const NtpClient = Ntp.Client(Std);

    const Worker = struct {
        fn run(server: Ntp.Ipv4Address) void {
            const client = NtpClient{ .server = server, .timeout_ms = 5000 };
            const resp = client.query(nowMs()) catch return;
            std.debug.assert(resp.stratum >= 1 and resp.stratum <= 15);
            std.debug.assert(resp.transmit_time_ms > 1_700_000_000_000);
        }
    };

    var threads: [3]std.Thread = undefined;
    const servers = [_]Ntp.Ipv4Address{ Ntp.Servers.aliyun, Ntp.Servers.cloudflare, Ntp.Servers.google };
    for (servers, 0..) |server, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{server});
    }
    for (&threads) |*t| t.join();
}

test "concurrent getTime from multiple threads" {
    const NtpClient = Ntp.Client(Std);

    const results = struct {
        var times: [4]i64 = .{ 0, 0, 0, 0 };
    };

    const Worker = struct {
        fn run(idx: usize) void {
            const client = NtpClient{ .server = Ntp.Servers.aliyun, .timeout_ms = 5000 };
            results.times[idx] = client.getTime(nowMs()) catch 0;
        }
    };

    var threads: [4]std.Thread = undefined;
    for (0..4) |i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{i});
    }
    for (&threads) |*t| t.join();

    var success_count: usize = 0;
    for (results.times) |t| {
        if (t > 1_700_000_000_000) success_count += 1;
    }
    try std.testing.expect(success_count >= 2);
}

test "concurrent queryRace from multiple threads" {
    const NtpClient = Ntp.Client(Std);

    const Worker = struct {
        fn run() void {
            const client = NtpClient{ .timeout_ms = 5000 };
            const servers = [_]Ntp.Ipv4Address{ Ntp.Servers.aliyun, Ntp.Servers.cloudflare };
            const resp = client.queryRace(nowMs(), &servers) catch return;
            std.debug.assert(resp.stratum >= 1);
        }
    };

    var threads: [3]std.Thread = undefined;
    for (0..3) |i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{});
    }
    for (&threads) |*t| t.join();
}
