const std = @import("std");
const base64 = std.base64.standard;
const embed = @import("../../mod.zig");
const RemoteHal = embed.websim.RemoteHal;

const Color565 = embed.hal.display.Color565;
const max_chunk_rows: u16 = 60;

pub const Display = struct {
    bus: ?*RemoteHal = null,
    width_px: u16 = 320,
    height_px: u16 = 240,
    enabled: bool = true,
    sleeping: bool = false,

    pub fn init() Display {
        return .{};
    }

    pub fn deinit(_: *Display) void {}

    pub fn width(self: *const Display) u16 {
        return self.width_px;
    }

    pub fn height(self: *const Display) u16 {
        return self.height_px;
    }

    pub fn setDisplayEnabled(self: *Display, enabled: bool) embed.hal.display.Error!void {
        self.enabled = enabled;
        self.emitState();
    }

    pub fn sleep(self: *Display, enabled: bool) embed.hal.display.Error!void {
        self.sleeping = enabled;
        self.emitState();
    }

    pub fn drawBitmap(
        self: *Display,
        x: u16,
        y: u16,
        w: u16,
        h: u16,
        data: []const Color565,
    ) embed.hal.display.Error!void {
        if (w == 0 or h == 0) return;
        if (data.len < @as(usize, w) * @as(usize, h)) return error.OutOfBounds;

        self.emitState();

        const row_pixels = @as(usize, w);
        var row: u16 = 0;
        while (row < h) {
            const chunk_h: u16 = @min(max_chunk_rows, h - row);
            const start = @as(usize, row) * row_pixels;
            const end = start + @as(usize, chunk_h) * row_pixels;
            try self.emitChunk(x, y + row, w, chunk_h, data[start..end]);
            row += chunk_h;
        }
    }

    fn emitState(self: *Display) void {
        const bus = self.bus orelse return;

        var buf: [160]u8 = undefined;
        const payload = std.fmt.bufPrint(
            &buf,
            "{{\"dev\":\"display\",\"kind\":\"state\",\"width\":{},\"height\":{},\"enabled\":{},\"sleeping\":{}}}",
            .{ self.width_px, self.height_px, self.enabled, self.sleeping },
        ) catch return;
        bus.emit(payload);
    }

    fn emitChunk(
        self: *Display,
        x: u16,
        y: u16,
        w: u16,
        h: u16,
        pixels: []const Color565,
    ) embed.hal.display.Error!void {
        const bus = self.bus orelse return;

        const raw = std.mem.sliceAsBytes(pixels);
        const encoded_len = base64.Encoder.calcSize(raw.len);

        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(std.heap.page_allocator);
        payload.ensureTotalCapacity(std.heap.page_allocator, encoded_len + 192) catch return error.DisplayError;

        const writer = payload.writer(std.heap.page_allocator);
        writer.print(
            "{{\"dev\":\"display\",\"kind\":\"frame\",\"format\":\"rgb565le\",\"width\":{},\"height\":{},\"x\":{},\"y\":{},\"w\":{},\"h\":{},\"pixels_b64\":\"",
            .{ self.width_px, self.height_px, x, y, w, h },
        ) catch return error.DisplayError;

        const start = payload.items.len;
        payload.resize(std.heap.page_allocator, start + encoded_len) catch return error.DisplayError;
        _ = base64.Encoder.encode(payload.items[start .. start + encoded_len], raw);

        writer.writeAll("\"}") catch return error.DisplayError;
        bus.emit(payload.items);
    }
};
