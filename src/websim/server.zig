const std = @import("std");
const ws_mod = @import("ws.zig");
const remote_hal_mod = @import("remote_hal.zig");

const RemoteHal = remote_hal_mod.RemoteHal;

const default_index_html = @embedFile("ui/themes/default/index.html");
const default_style_css = @embedFile("ui/themes/default/style.css");
const default_render_js = @embedFile("ui/themes/default/render.js");
const core_js = @embedFile("ui/core.js");
const hal_gpio_js = @embedFile("ui/hal/gpio.js");
const hal_display_js = @embedFile("ui/hal/display.js");
const hal_led_strip_js = @embedFile("ui/hal/led_strip.js");

pub const UiFiles = struct {
    index_html: []const u8 = default_index_html,
    style_css: []const u8 = default_style_css,
    render_js: []const u8 = default_render_js,
};

pub const ServeOptions = struct {
    port: u16 = 8080,
    host: [4]u8 = .{ 127, 0, 0, 1 },
    ui: UiFiles = .{},
};

pub fn serve(
    comptime hw: type,
    comptime firmware_entry: anytype,
    comptime SessionSetup: type,
    opts: ServeOptions,
) !void {
    const address = std.net.Address.initIp4(opts.host, opts.port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("[websim] listening on http://{}.{}.{}.{}:{d}\n", .{ opts.host[0], opts.host[1], opts.host[2], opts.host[3], opts.port });

    while (true) {
        const conn = server.accept() catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        handleConnection(hw, firmware_entry, SessionSetup, opts.ui, conn);
    }
}

fn handleConnection(
    comptime hw: type,
    comptime firmware_entry: anytype,
    comptime SessionSetup: type,
    ui: UiFiles,
    conn: std.net.Server.Connection,
) void {
    var request_buf: [8192]u8 = undefined;
    const n = conn.stream.read(&request_buf) catch {
        conn.stream.close();
        return;
    };
    if (n == 0) {
        conn.stream.close();
        return;
    }
    const request = request_buf[0..n];
    const path = ws_mod.parsePath(request) orelse {
        conn.stream.close();
        return;
    };

    if (std.mem.eql(u8, path, "/ws") and ws_mod.isUpgrade(request)) {
        ws_mod.handshake(conn.stream, request) catch {
            conn.stream.close();
            return;
        };
        const RunSessionFn = *const fn (std.net.Stream) void;
        const session_fn: RunSessionFn = &struct {
            fn run(stream: std.net.Stream) void {
                runSession(hw, firmware_entry, SessionSetup, stream);
            }
        }.run;
        const session_thread = std.Thread.spawn(.{}, session_fn.*, .{conn.stream}) catch {
            conn.stream.close();
            return;
        };
        session_thread.detach();
        return;
    }

    defer conn.stream.close();
    const js = "application/javascript; charset=utf-8";
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        ws_mod.sendHttp(conn.stream, "200 OK", "text/html; charset=utf-8", ui.index_html);
    } else if (std.mem.eql(u8, path, "/style.css")) {
        ws_mod.sendHttp(conn.stream, "200 OK", "text/css; charset=utf-8", ui.style_css);
    } else if (std.mem.eql(u8, path, "/render.js")) {
        ws_mod.sendHttp(conn.stream, "200 OK", js, ui.render_js);
    } else if (std.mem.eql(u8, path, "/core.js")) {
        ws_mod.sendHttp(conn.stream, "200 OK", js, core_js);
    } else if (std.mem.eql(u8, path, "/hal/gpio.js")) {
        ws_mod.sendHttp(conn.stream, "200 OK", js, hal_gpio_js);
    } else if (std.mem.eql(u8, path, "/hal/display.js")) {
        ws_mod.sendHttp(conn.stream, "200 OK", js, hal_display_js);
    } else if (std.mem.eql(u8, path, "/hal/led_strip.js")) {
        ws_mod.sendHttp(conn.stream, "200 OK", js, hal_led_strip_js);
    } else {
        ws_mod.sendHttp(conn.stream, "404 Not Found", "text/plain", "not found\n");
    }
}

fn runSession(
    comptime hw: type,
    comptime firmware_entry: anytype,
    comptime SessionSetup: type,
    stream: std.net.Stream,
) void {
    defer stream.close();

    std.debug.print("[websim] session started\n", .{});

    var running = std.atomic.Value(bool){ .raw = true };
    var bus = RemoteHal.initWs(stream, &running);

    var ctx = SessionSetup.setup(&bus, &running);
    SessionSetup.bind(&ctx, &bus);

    const reader = bus.startReader() catch {
        std.debug.print("[websim] failed to start reader thread\n", .{});
        return;
    };

    firmware_entry(hw, .{});

    running.store(false, .release);
    reader.join();

    SessionSetup.teardown(&ctx);

    std.debug.print("[websim] session ended\n", .{});
}
