//! RGB LED strip HAL wrapper.

const hal_marker = @import("marker.zig");

pub const Color = packed struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    pub const black = Color{};
    pub const white = Color{ .r = 255, .g = 255, .b = 255 };
    pub const red = Color{ .r = 255 };
    pub const green = Color{ .g = 255 };
    pub const blue = Color{ .b = 255 };

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn withBrightness(self: Color, brightness: u8) Color {
        return .{
            .r = @intCast((@as(u16, self.r) * brightness) / 255),
            .g = @intCast((@as(u16, self.g) * brightness) / 255),
            .b = @intCast((@as(u16, self.b) * brightness) / 255),
        };
    }

    pub fn lerp(a: Color, b: Color, t: u8) Color {
        const inv_t = 255 - t;
        return .{
            .r = @intCast((@as(u16, a.r) * inv_t + @as(u16, b.r) * t) / 255),
            .g = @intCast((@as(u16, a.g) * inv_t + @as(u16, b.g) * t) / 255),
            .b = @intCast((@as(u16, a.b) * inv_t + @as(u16, b.b) * t) / 255),
        };
    }
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .led_strip;
}

/// spec must define:
/// - Driver.setPixel(*Driver, index: u32, color: Color) void
/// - Driver.getPixelCount(*Driver) u32
/// - Driver.refresh(*Driver) void
/// - meta.id
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };

    comptime {
        _ = @as(*const fn (*BaseDriver, u32, Color) void, &BaseDriver.setPixel);
        _ = @as(*const fn (*BaseDriver) u32, &BaseDriver.getPixelCount);
        _ = @as(*const fn (*BaseDriver) void, &BaseDriver.refresh);
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .led_strip,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;

        driver: *Driver,
        brightness: u8 = 255,
        enabled: bool = true,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn getPixelCount(self: *Self) u32 {
            return self.driver.getPixelCount();
        }

        pub fn setPixel(self: *Self, index: u32, color: Color) void {
            if (!self.enabled) return;
            const adjusted = if (self.brightness < 255) color.withBrightness(self.brightness) else color;
            self.driver.setPixel(index, adjusted);
        }

        pub fn setPixels(self: *Self, colors: []const Color) void {
            const count = self.getPixelCount();
            for (colors, 0..) |c, i| {
                if (i >= count) break;
                self.setPixel(@intCast(i), c);
            }
            self.refresh();
        }

        pub fn setColor(self: *Self, color: Color) void {
            const count = self.getPixelCount();
            for (0..count) |i| self.setPixel(@intCast(i), color);
            self.refresh();
        }

        pub fn clear(self: *Self) void {
            self.setColor(.black);
        }

        pub fn refresh(self: *Self) void {
            self.driver.refresh();
        }

        pub fn setBrightness(self: *Self, brightness: u8) void {
            self.brightness = brightness;
        }

        pub fn getBrightness(self: *const Self) u8 {
            return self.brightness;
        }

        pub fn setEnabled(self: *Self, enabled: bool) void {
            self.enabled = enabled;
            if (!enabled) {
                const count = self.getPixelCount();
                for (0..count) |i| self.driver.setPixel(@intCast(i), .black);
                self.refresh();
            }
        }

        pub fn isEnabled(self: *const Self) bool {
            return self.enabled;
        }

        pub fn setGradient(self: *Self, start: Color, to: Color) void {
            const count = self.getPixelCount();
            if (count == 0) return;
            for (0..count) |i| {
                const t: u8 = if (count > 1) @intCast((i * 255) / (count - 1)) else 0;
                self.setPixel(@intCast(i), Color.lerp(start, to, t));
            }
            self.refresh();
        }
    };
}
