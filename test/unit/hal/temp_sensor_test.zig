const std = @import("std");
const testing = std.testing;
const embed = @import("embed");

const temp_sensor = embed.hal.temp_sensor;

test "TempSensor with mock driver" {
    const MockDriver = struct {
        temperature: f32 = 25.0,

        pub fn readCelsius(self: *@This()) temp_sensor.Error!f32 {
            return self.temperature;
        }
    };

    const temp_spec = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "temp.test" };
    };

    const TestTemp = temp_sensor.from(temp_spec);

    var driver = MockDriver{ .temperature = 25.0 };
    var temp = TestTemp.init(&driver);

    try std.testing.expectEqualStrings("temp.test", TestTemp.meta.id);

    const celsius = try temp.readCelsius();
    try std.testing.expectApproxEqAbs(@as(f32, 25.0), celsius, 0.01);

    const fahrenheit = try temp.readFahrenheit();
    try std.testing.expectApproxEqAbs(@as(f32, 77.0), fahrenheit, 0.01);

    const kelvin = try temp.readKelvin();
    try std.testing.expectApproxEqAbs(@as(f32, 298.15), kelvin, 0.01);
}

test "Temperature conversions" {
    const TestTemp = temp_sensor.from(struct {
        pub const Driver = struct {
            pub fn readCelsius(_: *@This()) temp_sensor.Error!f32 {
                return 0;
            }
        };
        pub const meta = .{ .id = "test" };
    });

    try std.testing.expectApproxEqAbs(@as(f32, 32.0), TestTemp.celsiusToFahrenheit(0), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 212.0), TestTemp.celsiusToFahrenheit(100), 0.01);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), TestTemp.fahrenheitToCelsius(32), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), TestTemp.fahrenheitToCelsius(212), 0.01);

    try std.testing.expectApproxEqAbs(@as(f32, 273.15), TestTemp.celsiusToKelvin(0), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 373.15), TestTemp.celsiusToKelvin(100), 0.01);
}
