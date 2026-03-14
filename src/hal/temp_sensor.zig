//! Temperature Sensor Hardware Abstraction Layer
//!
//! Provides a platform-independent interface for temperature sensors.

const hal_marker = @import("marker.zig");

pub const Error = error{
    NotReady,
    Timeout,
    SensorError,
};

// ============================================================================
// Private Type Marker (for hal.Board identification)
// ============================================================================

/// Check if a type is a TempSensor peripheral (internal use only)
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .temp_sensor;
}

// ============================================================================
// TempSensor HAL Wrapper
// ============================================================================

/// Temperature Sensor HAL component
///
/// Wraps a low-level Driver and provides:
/// - Unified readCelsius interface
/// - Celsius/Fahrenheit/Kelvin conversion
///
/// spec must define:
/// - `Driver`: struct with readCelsius method
/// - `meta`: metadata with an `id: []const u8`
///
/// Driver required methods:
/// - `fn readCelsius(self: *Self) Error!f32` - Read temperature in Celsius
pub fn from(comptime spec: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };

        _ = @as(*const fn (*BaseDriver) Error!f32, &BaseDriver.readCelsius);
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        /// Shared HAL marker for board-side peripheral classification.
        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .temp_sensor,
            .id = spec.meta.id,
        };

        /// Exported type for board-level composition
        pub const DriverType = Driver;

        /// Component metadata
        pub const meta = spec.meta;

        /// The underlying driver instance
        driver: *Driver,

        /// Initialize with a driver instance
        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        /// Read temperature in Celsius
        pub fn readCelsius(self: *Self) Error!f32 {
            return self.driver.readCelsius();
        }

        /// Read temperature in Fahrenheit
        pub fn readFahrenheit(self: *Self) Error!f32 {
            const celsius = try self.readCelsius();
            return celsiusToFahrenheit(celsius);
        }

        /// Read temperature in Kelvin
        pub fn readKelvin(self: *Self) Error!f32 {
            const celsius = try self.readCelsius();
            return celsiusToKelvin(celsius);
        }

        /// Convert Celsius to Fahrenheit
        pub fn celsiusToFahrenheit(celsius: f32) f32 {
            return celsius * 9.0 / 5.0 + 32.0;
        }

        /// Convert Fahrenheit to Celsius
        pub fn fahrenheitToCelsius(fahrenheit: f32) f32 {
            return (fahrenheit - 32.0) * 5.0 / 9.0;
        }

        /// Convert Celsius to Kelvin
        pub fn celsiusToKelvin(celsius: f32) f32 {
            return celsius + 273.15;
        }

        /// Convert Kelvin to Celsius
        pub fn kelvinToCelsius(kelvin: f32) f32 {
            return kelvin - 273.15;
        }
    };
}
