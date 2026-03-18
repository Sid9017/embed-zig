//! term - BLE Terminal Server
//!
//! Remote shell over BLE using the xfer chunked transfer protocol.
//! CLI sends command JSON via WRITE_X, firmware executes and returns
//! response JSON via READ_X.

const std = @import("std");
const embed = @import("../../../mod.zig");
const shell_mod = @import("shell.zig");
const transport_mod = @import("transport.zig");

const xfer_mod = embed.pkg.ble.xfer;

const CancellationToken = shell_mod.CancellationToken;
const encodeResponse = shell_mod.encodeResponse;
const GattTransport = transport_mod.GattTransport;
const HandlerFn = shell_mod.HandlerFn;
const ParsedCommand = shell_mod.ParsedCommand;
const parseRequest = shell_mod.parseRequest;
const Request = shell_mod.Request;
const ResponseWriter = shell_mod.ResponseWriter;
const Shell = shell_mod.Shell;

pub fn Server(comptime Runtime: type) type {
    comptime _ = embed.runtime.is(Runtime);

    const Transport = GattTransport(Runtime);
    const WX = xfer_mod.WriteX(Transport);
    const RX = xfer_mod.ReadX(Transport);

    return struct {
        const Self = @This();

        pub const Options = struct {
            mtu: u16 = 512,
            recv_buf_size: usize = 8192,
            resp_buf_size: usize = 4096,
            send_redundancy: u8 = 2,
            spawn_config: embed.runtime.thread.SpawnConfig = .{},
        };

        transport: *Transport,
        shell: Shell,
        options: Options,

        cancel_token: CancellationToken = .{},
        handler_thread: ?Runtime.Thread = null,
        handler_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
        loop_thread: ?Runtime.Thread = null,
        stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        handler_ctx: HandlerTaskCtx = .{},
        response_buf: [8192]u8 = undefined,
        response_len: usize = 0,

        pub fn init(transport: *Transport, options: Options) Self {
            return .{
                .transport = transport,
                .shell = Shell.init(),
                .options = options,
            };
        }

        pub fn start(self: *Self) !void {
            self.stopped.store(false, .release);
            self.loop_thread = try Runtime.Thread.spawn(self.options.spawn_config, loopEntry, @ptrCast(self));
        }

        pub fn run(self: *Self) void {
            self.stopped.store(false, .release);
            self.commandLoop();
        }

        pub fn stop(self: *Self) void {
            self.stopped.store(true, .release);
            self.cancel_token.cancel();
            self.transport.close();

            if (self.handler_thread) |*t| {
                t.join();
                self.handler_thread = null;
            }
            if (self.loop_thread) |*t| {
                t.join();
                self.loop_thread = null;
            }
        }

        fn loopEntry(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.commandLoop();
        }

        fn commandLoop(self: *Self) void {
            var recv_buf: [8192]u8 = undefined;
            const actual_recv_buf = recv_buf[0..@min(self.options.recv_buf_size, recv_buf.len)];

            while (!self.stopped.load(.acquire)) {
                var wx = WX.init(self.transport, actual_recv_buf, .{
                    .mtu = self.options.mtu,
                    .timeout_ms = 5_000,
                    .max_retries = 60,
                });

                const result = wx.run() catch |e| {
                    if (self.stopped.load(.acquire)) break;
                    switch (e) {
                        error.Timeout => continue,
                        else => continue,
                    }
                };

                const parsed = parseRequest(result.data) orelse continue;

                if (!self.handler_done.load(.acquire)) {
                    self.cancel_token.cancel();
                    if (self.handler_thread) |*t| {
                        t.join();
                        self.handler_thread = null;
                    }
                }

                self.cancel_token.reset();
                self.handler_done.store(false, .release);
                self.handler_ctx = .{
                    .server = self,
                    .cmd = parsed.cmd,
                    .args = parsed.args,
                    .id = parsed.id,
                };

                self.handler_thread = Runtime.Thread.spawn(self.options.spawn_config, handlerEntry, @ptrCast(&self.handler_ctx)) catch {
                    self.runHandler();
                    self.sendResponse();
                    continue;
                };

                if (self.handler_thread) |*t| {
                    t.join();
                    self.handler_thread = null;
                }

                if (self.stopped.load(.acquire)) break;
                self.sendResponse();
            }
        }

        const HandlerTaskCtx = struct {
            server: ?*Self = null,
            cmd: []const u8 = "",
            args: []const u8 = "",
            id: u32 = 0,
        };

        fn handlerEntry(ctx: ?*anyopaque) void {
            const task_ctx: *HandlerTaskCtx = @ptrCast(@alignCast(ctx orelse return));
            const server = task_ctx.server orelse return;
            server.runHandler();
        }

        fn runHandler(self: *Self) void {
            var resp_buf: [4096]u8 = undefined;
            const actual_resp_buf = resp_buf[0..@min(self.options.resp_buf_size, resp_buf.len)];

            const writer = self.shell.dispatch(
                self.handler_ctx.cmd,
                self.handler_ctx.args,
                self.handler_ctx.id,
                0,
                &self.cancel_token,
                actual_resp_buf,
            );

            var json_buf: [8192]u8 = undefined;
            const json = encodeResponse(
                &json_buf,
                self.handler_ctx.id,
                writer.output(),
                writer.err_msg,
                writer.exit_code,
            );

            const n = @min(json.len, self.response_buf.len);
            @memcpy(self.response_buf[0..n], json[0..n]);
            self.response_len = n;
            self.handler_done.store(true, .release);
        }

        fn sendResponse(self: *Self) void {
            if (self.response_len == 0) return;

            var rx = RX.init(self.transport, self.response_buf[0..self.response_len], .{
                .mtu = self.options.mtu,
                .send_redundancy = self.options.send_redundancy,
                .start_timeout_ms = 10_000,
                .ack_timeout_ms = 30_000,
            });

            rx.run() catch {};
            self.response_len = 0;
        }
    };
}
