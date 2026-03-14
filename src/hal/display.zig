//! Display HAL — SPI LCD panel transport.
//!
//! Pure transport layer: no framebuffer, no pixel operations.
//! The driver initializes the SPI bus + LCD panel and provides
//! `drawBitmap` to push contiguous pixel data to a screen region.
//! All buffer management belongs in the application layer.

const hal_marker = @import("marker.zig");

pub const Error = error{
    OutOfBounds,
    Busy,
    Timeout,
    DisplayError,
};

/// RGB565 (0bRRRRRGGGGGGBBBBB)
pub const Color565 = u16;

pub fn rgb565(r: u8, g: u8, b: u8) Color565 {
    const rr: u16 = @intCast((@as(u16, r) >> 3) & 0x1F);
    const gg: u16 = @intCast((@as(u16, g) >> 2) & 0x3F);
    const bb: u16 = @intCast((@as(u16, b) >> 3) & 0x1F);
    return (rr << 11) | (gg << 5) | bb;
}

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .display;
}

/// spec must define:
/// - Driver.width(*const Driver) u16
/// - Driver.height(*const Driver) u16
/// - Driver.setDisplayEnabled(*Driver, bool) Error!void
/// - Driver.sleep(*Driver, bool) Error!void
/// - Driver.drawBitmap(*Driver, x: u16, y: u16, w: u16, h: u16, data: []const Color565) Error!void
/// - meta.id
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };

    comptime {
        _ = @as(*const fn (*const BaseDriver) u16, &BaseDriver.width);
        _ = @as(*const fn (*const BaseDriver) u16, &BaseDriver.height);
        _ = @as(*const fn (*BaseDriver, bool) Error!void, &BaseDriver.setDisplayEnabled);
        _ = @as(*const fn (*BaseDriver, bool) Error!void, &BaseDriver.sleep);
        _ = @as(*const fn (*BaseDriver, u16, u16, u16, u16, []const Color565) Error!void, &BaseDriver.drawBitmap);

        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .display,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn width(self: *const Self) u16 {
            return self.driver.width();
        }

        pub fn height(self: *const Self) u16 {
            return self.driver.height();
        }

        pub fn setDisplayEnabled(self: *Self, enabled: bool) Error!void {
            return self.driver.setDisplayEnabled(enabled);
        }

        /// Enter or exit sleep mode (screen off / low power).
        pub fn sleep(self: *Self, enabled: bool) Error!void {
            return self.driver.sleep(enabled);
        }

        /// Write a rectangular block of contiguous pixels to the display.
        /// `data` must contain exactly w * h pixels, tightly packed (no stride).
        pub fn drawBitmap(self: *Self, x: u16, y: u16, w: u16, h: u16, data: []const Color565) Error!void {
            if (w == 0 or h == 0) return;
            if (@as(u32, x) + w > self.width() or @as(u32, y) + h > self.height()) return error.OutOfBounds;
            if (data.len < @as(usize, w) * @as(usize, h)) return error.OutOfBounds;
            return self.driver.drawBitmap(x, y, w, h, data);
        }
    };
}
