//! AT response parsing unit tests (AP-01 to AP-11). See plan.md §8.4.

const std = @import("std");
const embed = @import("embed");
const parse = embed.pkg.cellular.at.parse;
const types = embed.pkg.cellular.types;

// AP-01
test "isOk: OK returns true, others false" {
    try std.testing.expect(parse.isOk("OK"));
    try std.testing.expect(parse.isOk("OK\r"));
    try std.testing.expect(!parse.isOk("ERROR"));
    try std.testing.expect(!parse.isOk("OK "));
    try std.testing.expect(!parse.isOk("+CME ERROR: 10"));
    try std.testing.expect(!parse.isOk(""));
}

// AP-02
test "isError: ERROR returns true, CME/CMS do not" {
    try std.testing.expect(parse.isError("ERROR"));
    try std.testing.expect(parse.isError("ERROR\r"));
    try std.testing.expect(!parse.isError("OK"));
    try std.testing.expect(!parse.isError("+CME ERROR: 10"));
    try std.testing.expect(!parse.isError("+CMS ERROR: 500"));
    try std.testing.expect(!parse.isError(""));
}

// AP-03
test "parseCmeError: extracts numeric code" {
    try std.testing.expectEqual(@as(?u16, 10), parse.parseCmeError("+CME ERROR: 10"));
    try std.testing.expectEqual(@as(?u16, 10), parse.parseCmeError("+CME ERROR: 10\r"));
    try std.testing.expectEqual(@as(?u16, 0), parse.parseCmeError("+CME ERROR: 0"));
    try std.testing.expectEqual(@as(?u16, null), parse.parseCmeError("ERROR"));
    try std.testing.expectEqual(@as(?u16, null), parse.parseCmeError("+CMS ERROR: 500"));
    try std.testing.expectEqual(@as(?u16, null), parse.parseCmeError(""));
}

// AP-04
test "parseCmsError: extracts numeric code" {
    try std.testing.expectEqual(@as(?u16, 500), parse.parseCmsError("+CMS ERROR: 500"));
    try std.testing.expectEqual(@as(?u16, 500), parse.parseCmsError("+CMS ERROR: 500\r"));
    try std.testing.expectEqual(@as(?u16, 301), parse.parseCmsError("+CMS ERROR: 301"));
    try std.testing.expectEqual(@as(?u16, null), parse.parseCmsError("+CME ERROR: 10"));
    try std.testing.expectEqual(@as(?u16, null), parse.parseCmsError("ERROR"));
}

// AP-05
test "parsePrefix: extracts value after prefix" {
    const v1 = parse.parsePrefix("+CSQ: 20,0", "+CSQ:");
    try std.testing.expect(v1 != null);
    try std.testing.expectEqualStrings("20,0", v1.?);

    const v2 = parse.parsePrefix("+CPIN: READY\r", "+CPIN:");
    try std.testing.expect(v2 != null);
    try std.testing.expectEqualStrings("READY", v2.?);

    try std.testing.expect(parse.parsePrefix("OK", "+CSQ:") == null);
    try std.testing.expect(parse.parsePrefix("", "+CSQ:") == null);
}

// AP-06
test "parseCsq: normal signal" {
    const info = parse.parseCsq("20,0");
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(i8, -73), info.?.rssi);
    try std.testing.expectEqual(@as(u8, 0), info.?.ber.?);
}

// AP-07
test "parseCsq: no signal (99,99) returns null" {
    try std.testing.expect(parse.parseCsq("99,99") == null);
}

// AP-08
test "parseCpin: READY and SIM PIN" {
    try std.testing.expectEqual(types.SimStatus.ready, parse.parseCpin("READY").?);
    try std.testing.expectEqual(types.SimStatus.pin_required, parse.parseCpin("SIM PIN").?);
    try std.testing.expectEqual(types.SimStatus.puk_required, parse.parseCpin("SIM PUK").?);
    try std.testing.expectEqual(types.SimStatus.not_inserted, parse.parseCpin("NOT INSERTED").?);
    try std.testing.expect(parse.parseCpin("GARBAGE") == null);
}

// AP-09
test "parseCreg: registered_home and registered_roaming" {
    try std.testing.expectEqual(types.CellularRegStatus.registered_home, parse.parseCreg("0,1").?);
    try std.testing.expectEqual(types.CellularRegStatus.registered_roaming, parse.parseCreg("0,5").?);
    try std.testing.expectEqual(types.CellularRegStatus.not_registered, parse.parseCreg("0,0").?);
    try std.testing.expectEqual(types.CellularRegStatus.searching, parse.parseCreg("0,2").?);
    try std.testing.expectEqual(types.CellularRegStatus.denied, parse.parseCreg("0,3").?);
    try std.testing.expectEqual(types.CellularRegStatus.unknown, parse.parseCreg("0,4").?);
}

// AP-10
test "rssiToDbm: CSQ to dBm conversion" {
    try std.testing.expectEqual(@as(i8, -73), parse.rssiToDbm(20));
    try std.testing.expectEqual(@as(i8, -113), parse.rssiToDbm(0));
    try std.testing.expectEqual(@as(i8, -51), parse.rssiToDbm(31));
    try std.testing.expectEqual(@as(i8, -113), parse.rssiToDbm(99));
}

// AP-11
test "rssiToPercent: dBm to percentage" {
    try std.testing.expectEqual(@as(u8, 100), parse.rssiToPercent(-50));
    try std.testing.expectEqual(@as(u8, 100), parse.rssiToPercent(-51));
    try std.testing.expectEqual(@as(u8, 0), parse.rssiToPercent(-113));
    try std.testing.expectEqual(@as(u8, 0), parse.rssiToPercent(-120));
    const mid = parse.rssiToPercent(-80);
    try std.testing.expect(mid >= 45 and mid <= 55);
}
