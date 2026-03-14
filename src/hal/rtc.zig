//! RTC HAL components (reader/writer).

const std = @import("std");
const hal_marker = @import("marker.zig");

pub const WriterError = error{
    Overflow,
    SetNowFailed,
};

pub const Timestamp = struct {
    epoch_secs: i64,

    pub fn fromEpoch(epoch: i64) Timestamp {
        return .{ .epoch_secs = epoch };
    }

    pub fn toEpoch(self: Timestamp) i64 {
        return self.epoch_secs;
    }

    pub fn toDatetime(self: Timestamp) Datetime {
        return Datetime.fromEpoch(self.epoch_secs);
    }

    pub fn format(self: Timestamp, buf: []u8) []const u8 {
        return self.toDatetime().format(buf);
    }
};

pub const Datetime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,

    pub fn fromEpoch(epoch: i64) Datetime {
        var days = @divFloor(epoch, 86400);
        var secs = @mod(epoch, 86400);
        if (secs < 0) {
            secs += 86400;
            days -= 1;
        }

        const hour: u8 = @intCast(@divFloor(secs, 3600));
        secs = @mod(secs, 3600);
        const minute: u8 = @intCast(@divFloor(secs, 60));
        const second: u8 = @intCast(@mod(secs, 60));

        var year: i32 = 1970;
        while (true) {
            const d: i64 = if (isLeapYear(year)) 366 else 365;
            if (days < d) break;
            days -= d;
            year += 1;
        }

        const month_days = if (isLeapYear(year)) leap_month_days else normal_month_days;
        var month: u8 = 1;
        while (month <= 12) : (month += 1) {
            if (days < month_days[month - 1]) break;
            days -= month_days[month - 1];
        }

        return .{
            .year = @intCast(year),
            .month = month,
            .day = @intCast(days + 1),
            .hour = hour,
            .minute = minute,
            .second = second,
        };
    }

    pub fn toEpoch(self: Datetime) i64 {
        var days: i64 = 0;
        var y: i32 = 1970;
        while (y < self.year) : (y += 1) {
            days += if (isLeapYear(y)) 366 else 365;
        }

        const month_days = if (isLeapYear(@intCast(self.year))) leap_month_days else normal_month_days;
        var m: u8 = 1;
        while (m < self.month) : (m += 1) {
            days += month_days[m - 1];
        }
        days += self.day - 1;

        return days * 86400 + @as(i64, self.hour) * 3600 + @as(i64, self.minute) * 60 + self.second;
    }

    pub fn format(self: Datetime, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            self.year,
            self.month,
            self.day,
            self.hour,
            self.minute,
            self.second,
        }) catch "????-??-??T??:??:??Z";
    }

    fn isLeapYear(year: i32) bool {
        return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    }

    const normal_month_days = [12]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap_month_days = [12]i64{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
};

pub const reader = struct {
    pub fn is(comptime T: type) bool {
        if (@typeInfo(T) != .@"struct") return false;
        if (!@hasDecl(T, "_hal_marker")) return false;
        const marker = T._hal_marker;
        if (@TypeOf(marker) != hal_marker.Marker) return false;
        return marker.kind == .rtc;
    }

    pub fn from(comptime spec: type) type {
        comptime {
            const BaseDriver = switch (@typeInfo(spec.Driver)) {
                .pointer => |p| p.child,
                else => spec.Driver,
            };
            _ = @as(*const fn (*BaseDriver) u64, &BaseDriver.uptime);
            _ = @as(*const fn (*BaseDriver) ?i64, &BaseDriver.nowMs);
            _ = @as([]const u8, spec.meta.id);
        }

        const Driver = spec.Driver;
        return struct {
            const Self = @This();

            pub const _hal_marker: hal_marker.Marker = .{
                .kind = .rtc,
                .id = spec.meta.id,
            };
            pub const DriverType = Driver;
            pub const meta = spec.meta;

            driver: *Driver,

            pub fn init(driver: *Driver) Self {
                return .{ .driver = driver };
            }

            pub fn uptime(self: *Self) u64 {
                return self.driver.uptime();
            }

            pub fn now(self: *Self) ?Timestamp {
                if (self.driver.nowMs()) |epoch_ms| {
                    return Timestamp.fromEpoch(msToSecsFloor(epoch_ms));
                }
                return null;
            }

            pub fn nowMs(self: *Self) ?i64 {
                return self.driver.nowMs();
            }

            pub fn isSynced(self: *Self) bool {
                return self.driver.nowMs() != null;
            }
        };
    }
};

pub const writer = struct {
    pub fn is(comptime T: type) bool {
        if (@typeInfo(T) != .@"struct") return false;
        if (!@hasDecl(T, "_hal_marker")) return false;
        const marker = T._hal_marker;
        if (@TypeOf(marker) != hal_marker.Marker) return false;
        return marker.kind == .rtc;
    }

    pub fn from(comptime spec: type) type {
        comptime {
            const BaseDriver = switch (@typeInfo(spec.Driver)) {
                .pointer => |p| p.child,
                else => spec.Driver,
            };
            _ = @as(*const fn (*BaseDriver, i64) WriterError!void, &BaseDriver.setNowMs);
            _ = @as([]const u8, spec.meta.id);
        }

        const Driver = spec.Driver;
        return struct {
            const Self = @This();

            pub const _hal_marker: hal_marker.Marker = .{
                .kind = .rtc,
                .id = spec.meta.id,
            };
            pub const DriverType = Driver;
            pub const meta = spec.meta;

            driver: *Driver,

            pub fn init(driver: *Driver) Self {
                return .{ .driver = driver };
            }

            pub fn setNowMs(self: *Self, epoch_ms: i64) WriterError!void {
                return self.driver.setNowMs(epoch_ms);
            }

            pub fn setTimestamp(self: *Self, ts: Timestamp) WriterError!void {
                const epoch_ms = try secsToMs(ts.epoch_secs);
                return self.driver.setNowMs(epoch_ms);
            }

            pub fn setDatetime(self: *Self, dt: Datetime) WriterError!void {
                const epoch_ms = try secsToMs(dt.toEpoch());
                return self.driver.setNowMs(epoch_ms);
            }
        };
    }
};

fn msToSecsFloor(ms: i64) i64 {
    return @divFloor(ms, 1000);
}

fn secsToMs(secs: i64) WriterError!i64 {
    const out = @mulWithOverflow(secs, 1000);
    if (out[1] != 0) return error.Overflow;
    return out[0];
}
