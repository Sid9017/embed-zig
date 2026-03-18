const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const shell_mod = embed.pkg.ble.term.shell;

test "CancellationToken: init not cancelled" {
    var token = shell_mod.CancellationToken{};
    try std.testing.expect(!token.isCancelled());
}

test "CancellationToken: cancel and reset" {
    var token = shell_mod.CancellationToken{};
    token.cancel();
    try std.testing.expect(token.isCancelled());
    token.reset();
    try std.testing.expect(!token.isCancelled());
}

test "ResponseWriter: write and output" {
    var buf: [64]u8 = undefined;
    var w = shell_mod.ResponseWriter.init(&buf);
    w.write("hello ");
    w.write("world");
    try std.testing.expectEqualSlices(u8, "hello world", w.output());
}

test "ResponseWriter: print formatted" {
    var buf: [64]u8 = undefined;
    var w = shell_mod.ResponseWriter.init(&buf);
    w.print("count={d}", .{42});
    try std.testing.expectEqualSlices(u8, "count=42", w.output());
}

test "ResponseWriter: overflow truncates" {
    var buf: [5]u8 = undefined;
    var w = shell_mod.ResponseWriter.init(&buf);
    w.write("hello world");
    try std.testing.expectEqualSlices(u8, "hello", w.output());
}

test "Shell: register and dispatch" {
    const handler = struct {
        pub fn serve(req: *const shell_mod.Request, w: *shell_mod.ResponseWriter) void {
            _ = req;
            w.write("ok");
        }
    }.serve;

    var shell = shell_mod.Shell.init();
    try shell.register("echo", handler, null);

    var cancel = shell_mod.CancellationToken{};
    var resp_buf: [256]u8 = undefined;
    const writer = shell.dispatch("echo", "", 1, 0x40, &cancel, &resp_buf);
    try std.testing.expectEqualSlices(u8, "ok", writer.output());
    try std.testing.expectEqual(@as(i8, 0), writer.exit_code);
}

test "Shell: unknown command sets error" {
    var shell = shell_mod.Shell.init();
    var cancel = shell_mod.CancellationToken{};
    var resp_buf: [256]u8 = undefined;
    const writer = shell.dispatch("nonexistent", "", 1, 0x40, &cancel, &resp_buf);
    try std.testing.expectEqual(@as(i8, 1), writer.exit_code);
    try std.testing.expectEqualSlices(u8, "unknown command", writer.err_msg);
}

test "Shell: handler receives args and user_ctx" {
    const Counter = struct { value: u32 = 0 };
    var counter = Counter{};

    const handler = struct {
        pub fn serve(req: *const shell_mod.Request, w: *shell_mod.ResponseWriter) void {
            const ctr: *Counter = @ptrCast(@alignCast(req.user_ctx));
            ctr.value += 1;
            w.print("args={s}", .{req.args});
        }
    }.serve;

    var shell = shell_mod.Shell.init();
    try shell.register("test", handler, @ptrCast(&counter));

    var cancel = shell_mod.CancellationToken{};
    var resp_buf: [256]u8 = undefined;
    const writer = shell.dispatch("test", "foo bar", 1, 0x40, &cancel, &resp_buf);
    try std.testing.expectEqualSlices(u8, "args=foo bar", writer.output());
    try std.testing.expectEqual(@as(u32, 1), counter.value);
}

test "parseRequest: valid JSON" {
    const parsed = shell_mod.parseRequest("{\"cmd\":\"ls -la\",\"id\":42}") orelse unreachable;
    try std.testing.expectEqualSlices(u8, "ls", parsed.cmd);
    try std.testing.expectEqualSlices(u8, "-la", parsed.args);
    try std.testing.expectEqual(@as(u32, 42), parsed.id);
}

test "parseRequest: no args" {
    const parsed = shell_mod.parseRequest("{\"cmd\":\"sys.info\",\"id\":1}") orelse unreachable;
    try std.testing.expectEqualSlices(u8, "sys.info", parsed.cmd);
    try std.testing.expectEqualSlices(u8, "", parsed.args);
    try std.testing.expectEqual(@as(u32, 1), parsed.id);
}

test "parseRequest: invalid JSON returns null" {
    try std.testing.expect(shell_mod.parseRequest("garbage") == null);
    try std.testing.expect(shell_mod.parseRequest("{}") == null);
    try std.testing.expect(shell_mod.parseRequest("{\"cmd\":\"ls\"}") == null);
}

test "encodeResponse: basic" {
    var buf: [256]u8 = undefined;
    const resp = shell_mod.encodeResponse(&buf, 1, "file1\nfile2", "", 0);
    try std.testing.expectEqualSlices(u8, "{\"id\":1,\"out\":\"file1\\nfile2\",\"err\":\"\",\"exit\":0}", resp);
}

test "encodeResponse: with error" {
    var buf: [256]u8 = undefined;
    const resp = shell_mod.encodeResponse(&buf, 5, "", "not found", 1);
    try std.testing.expectEqualSlices(u8, "{\"id\":5,\"out\":\"\",\"err\":\"not found\",\"exit\":1}", resp);
}

test "encodeResponse: negative exit code" {
    var buf: [256]u8 = undefined;
    const resp = shell_mod.encodeResponse(&buf, 1, "", "killed", -1);
    try std.testing.expectEqualSlices(u8, "{\"id\":1,\"out\":\"\",\"err\":\"killed\",\"exit\":-1}", resp);
}
