//! bleterm — BLE Terminal CLI tool (macOS)
//!
//! Connects to a BLE device running the term server and sends commands
//! via the Ble.xfer protocol over GATT.
//!
//! Usage:
//!   bleterm scan                         Scan for devices
//!   bleterm <cmd> --id=<uuid>            Send command, print response
//!   bleterm <cmd> --name=<prefix>        Connect by name prefix
//!   bleterm shell --id=<uuid>            Interactive REPL

const std = @import("std");
const ble = @import("ble.zig");
const embed = @import("embed");
const Ble = embed.pkg.ble;

fn writeOut(bytes: []const u8) void {
    std.fs.File.stdout().writeAll(bytes) catch {};
}

fn writeErr(bytes: []const u8) void {
    std.fs.File.stderr().writeAll(bytes) catch {};
}

fn printOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeOut(s);
}

fn printErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeErr(s);
}

pub fn main() void {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const args = std.process.argsAlloc(arena) catch {
        writeErr("Error: failed to read args\n");
        std.process.exit(1);
    };

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    const subcmd = args[1];

    if (std.mem.eql(u8, subcmd, "scan")) {
        cmdScan();
    } else if (std.mem.eql(u8, subcmd, "shell")) {
        cmdShell(args[2..]);
    } else if (std.mem.eql(u8, subcmd, "help") or std.mem.eql(u8, subcmd, "--help")) {
        printUsage();
    } else {
        cmdExec(subcmd, args[2..]);
    }
}

fn printUsage() void {
    writeOut(
        \\bleterm — BLE Terminal
        \\
        \\Usage:
        \\  bleterm scan                     Scan for devices
        \\  bleterm <cmd> --id=<uuid>        Send command
        \\  bleterm <cmd> --name=<prefix>    Connect by name prefix
        \\  bleterm shell --id=<uuid>        Interactive REPL
        \\
        \\Examples:
        \\  bleterm scan
        \\  bleterm sys.info --name=MyDevice
        \\  bleterm "echo hello" --id=ABCD1234
        \\  bleterm shell --name=MyDevice
        \\
    );
}

fn cmdScan() void {
    writeOut("Scanning for BLE devices...\n\n");

    var scanner = ble.Scanner.init();
    scanner.scan(5000);

    if (scanner.count == 0) {
        writeOut("No devices found.\n");
        return;
    }

    printOut("{s:<40} {s:<8} {s}\n", .{ "UUID", "RSSI", "Name" });
    printOut("{s:<40} {s:<8} {s}\n", .{ "----", "----", "----" });

    for (scanner.results[0..scanner.count]) |r| {
        printOut("{s:<40} {d:<8} {s}\n", .{
            r.uuidSlice(),
            r.rssi,
            r.nameSlice(),
        });
    }
}

fn cmdExec(cmd: []const u8, args: []const []const u8) void {
    const target = parseTarget(args) orelse {
        writeErr("Error: --id=<uuid> or --name=<prefix> required\n");
        std.process.exit(1);
    };

    var conn = ble.Connection.init();
    defer conn.disconnect();

    switch (target) {
        .id => |uuid| conn.connect(uuid) catch {
            writeErr("Error: failed to connect\n");
            std.process.exit(1);
        },
        .name => |prefix| conn.connectByName(prefix) catch {
            writeErr("Error: failed to connect\n");
            std.process.exit(1);
        },
    }

    if (!conn.connected) {
        writeErr("Error: failed to connect\n");
        std.process.exit(1);
    }

    var cmd_buf: [1024]u8 = undefined;
    const cmd_json = std.fmt.bufPrint(&cmd_buf, "{{\"cmd\":\"{s}\",\"id\":1}}", .{cmd}) catch {
        writeErr("Error: command too long\n");
        std.process.exit(1);
    };

    var rx = Ble.xfer.ReadX(ble.BleTransport).init(&conn.transport, cmd_json, .{
        .mtu = conn.mtu,
        .send_redundancy = 2,
    });
    rx.run() catch |e| {
        printErr("Error sending command: {}\n", .{e});
        std.process.exit(1);
    };

    var recv_buf: [16384]u8 = undefined;
    var wx = Ble.xfer.WriteX(ble.BleTransport).init(&conn.transport, &recv_buf, .{
        .mtu = conn.mtu,
    });
    const result = wx.run() catch |e| {
        printErr("Error receiving response: {}\n", .{e});
        std.process.exit(1);
    };

    writeOut(result.data);
    writeOut("\n");
}

fn cmdShell(args: []const []const u8) void {
    const target = parseTarget(args) orelse {
        writeErr("Error: --id=<uuid> or --name=<prefix> required\n");
        std.process.exit(1);
    };

    var conn = ble.Connection.init();
    defer conn.disconnect();

    switch (target) {
        .id => |uuid| conn.connect(uuid) catch {
            writeErr("Error: failed to connect\n");
            std.process.exit(1);
        },
        .name => |prefix| conn.connectByName(prefix) catch {
            writeErr("Error: failed to connect\n");
            std.process.exit(1);
        },
    }

    if (!conn.connected) {
        writeErr("Error: failed to connect\n");
        std.process.exit(1);
    }

    writeOut("bleterm shell (type 'exit' to quit)\n");

    const stdin = std.fs.File.stdin();
    var id: u32 = 1;

    while (true) {
        writeOut("> ");

        var line_buf: [1024]u8 = undefined;
        const n = stdin.read(&line_buf) catch break;
        if (n == 0) break;

        // Strip trailing newline
        var line_len = n;
        while (line_len > 0 and (line_buf[line_len - 1] == '\n' or line_buf[line_len - 1] == '\r')) {
            line_len -= 1;
        }
        if (line_len == 0) continue;
        const line = line_buf[0..line_len];

        if (std.mem.eql(u8, line, "exit") or std.mem.eql(u8, line, "quit")) break;

        var cmd_buf: [1024]u8 = undefined;
        const cmd_json = std.fmt.bufPrint(&cmd_buf, "{{\"cmd\":\"{s}\",\"id\":{d}}}", .{ line, id }) catch continue;

        var rx = Ble.xfer.ReadX(ble.BleTransport).init(&conn.transport, cmd_json, .{
            .mtu = conn.mtu,
            .send_redundancy = 2,
        });
        rx.run() catch |e| {
            printErr("send error: {}\n", .{e});
            continue;
        };

        var recv_buf: [16384]u8 = undefined;
        var wx = Ble.xfer.WriteX(ble.BleTransport).init(&conn.transport, &recv_buf, .{
            .mtu = conn.mtu,
        });
        const result = wx.run() catch |e| {
            printErr("recv error: {}\n", .{e});
            continue;
        };

        writeOut(result.data);
        writeOut("\n");

        id += 1;
    }

    writeOut("bye\n");
}

// ============================================================================
// Arg parsing
// ============================================================================

const Target = union(enum) {
    id: []const u8,
    name: []const u8,
};

fn parseTarget(args: []const []const u8) ?Target {
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--id=")) {
            return .{ .id = arg[5..] };
        }
        if (std.mem.startsWith(u8, arg, "--name=")) {
            return .{ .name = arg[7..] };
        }
    }
    return null;
}
