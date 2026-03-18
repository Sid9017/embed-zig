const std = @import("std");
const embed = @import("embed");
const commands = embed.pkg.cellular.at.commands;
const types = embed.pkg.cellular.types;

test "GetCpin parseResponse" {
    try std.testing.expectEqual(types.SimStatus.ready, commands.GetCpin.parseResponse("+CPIN: READY").?);
    try std.testing.expectEqual(types.SimStatus.pin_required, commands.GetCpin.parseResponse("+CPIN: SIM PIN").?);
}

test "GetCereg parseResponse" {
    try std.testing.expectEqual(types.CellularRegStatus.registered_home, commands.GetCereg.parseResponse("+CEREG: 0,1").?);
    try std.testing.expectEqual(types.CellularRegStatus.searching, commands.GetCereg.parseResponse("+CEREG: 2,2").?);
}

test "GetCreg parseResponse" {
    try std.testing.expectEqual(types.CellularRegStatus.registered_roaming, commands.GetCreg.parseResponse("+CREG: 0,5").?);
}

test "SetEchoOff write" {
    var buf: [16]u8 = undefined;
    const n = commands.SetEchoOff.write(&buf);
    try std.testing.expectEqualStrings("ATE0\r\n", buf[0..n]);
}
