//! HAL Board — peripheral aggregation and auto-initialization.
//!
//! Discovers HAL peripheral types from a spec (via `_hal_marker`),
//! auto-initializes drivers and wrappers, and exposes typed accessors.
//!
//! Event handling is NOT part of the board. Use `pkg/event.Bus` for that.

const std = @import("std");
const hal_marker = @import("marker.zig");
const rtc_mod = @import("rtc.zig");

fn getMarkedKind(comptime T: type) ?hal_marker.Kind {
    if (@typeInfo(T) != .@"struct") return null;
    if (!@hasDecl(T, "_hal_marker")) return null;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return null;
    return marker.kind;
}

fn findPeripheralType(comptime spec: type, comptime kind: hal_marker.Kind) type {
    var found = false;
    var result: type = void;

    inline for (@typeInfo(spec).@"struct".decls) |decl| {
        if (!@hasDecl(spec, decl.name)) continue;

        const DeclType = @TypeOf(@field(spec, decl.name));
        if (@typeInfo(DeclType) != .type) continue;

        const Candidate = @field(spec, decl.name);
        if (getMarkedKind(Candidate)) |k| {
            if (k == kind) {
                if (found) {
                    @compileError(std.fmt.comptimePrint(
                        "spec contains multiple HAL peripherals for marker kind '{s}'",
                        .{@tagName(kind)},
                    ));
                }
                found = true;
                result = Candidate;
            }
        }
    }

    return result;
}

fn findRtcReaderType(comptime spec: type) type {
    var found = false;
    var result: type = void;

    inline for (@typeInfo(spec).@"struct".decls) |decl| {
        if (!@hasDecl(spec, decl.name)) continue;

        const DeclType = @TypeOf(@field(spec, decl.name));
        if (@typeInfo(DeclType) != .type) continue;

        const Candidate = @field(spec, decl.name);
        if (getMarkedKind(Candidate)) |kind| {
            if (kind != .rtc) continue;

            if (!@hasDecl(Candidate, "uptime") or !@hasDecl(Candidate, "nowMs")) continue;

            _ = @as(*const fn (*Candidate) u64, &Candidate.uptime);
            _ = @as(*const fn (*Candidate) ?i64, &Candidate.nowMs);

            if (found) {
                @compileError("spec has multiple rtc reader-like peripherals; keep only one");
            }
            found = true;
            result = Candidate;
        }
    }

    if (!found) {
        @compileError("spec must provide one rtc reader peripheral (marker kind .rtc, with uptime/nowMs)");
    }

    return result;
}

fn driverTypeOf(comptime PeripheralType: type) type {
    if (PeripheralType == void) return void;
    if (!@hasDecl(PeripheralType, "DriverType")) {
        @compileError("HAL peripheral type must expose DriverType");
    }
    return PeripheralType.DriverType;
}

fn validatePeripheralType(comptime PeripheralType: type, comptime expected_kind: hal_marker.Kind) void {
    if (PeripheralType == void) return;

    if (getMarkedKind(PeripheralType)) |k| {
        if (k != expected_kind) {
            @compileError(std.fmt.comptimePrint(
                "HAL peripheral marker kind mismatch: expected '{s}', got '{s}'",
                .{ @tagName(expected_kind), @tagName(k) },
            ));
        }
    } else {
        @compileError("HAL peripheral is missing valid shared marker (_hal_marker: hal.marker.Marker)");
    }

    const DriverType = driverTypeOf(PeripheralType);

    if (!@hasDecl(PeripheralType, "init")) {
        @compileError("HAL peripheral must expose init(*DriverType)");
    }
    _ = @as(*const fn (*DriverType) PeripheralType, &PeripheralType.init);

    if (!@hasDecl(DriverType, "init")) {
        @compileError("driver type must expose init() for board auto-init");
    }

    const init_ret = @typeInfo(@TypeOf(DriverType.init)).@"fn".return_type orelse
        @compileError("driver init must have a return type");

    switch (@typeInfo(init_ret)) {
        .error_union => |eu| {
            if (eu.payload != DriverType) {
                @compileError("driver init() error-union payload must be DriverType");
            }
        },
        else => {
            if (init_ret != DriverType) {
                @compileError("driver init() must return DriverType or !DriverType");
            }
        },
    }

    if (comptime @hasDecl(DriverType, "deinit")) {
        _ = @as(*const fn (*DriverType) void, &DriverType.deinit);
    }
}

fn driverInit(comptime DriverType: type) !DriverType {
    return DriverType.init();
}

fn driverDeinit(comptime DriverType: type, driver: *DriverType) void {
    if (comptime @hasDecl(DriverType, "deinit")) {
        driver.deinit();
    }
}

pub fn Board(comptime spec: type) type {
    comptime {
        if (!@hasDecl(spec, "meta")) {
            @compileError("spec must define meta.id");
        }
        _ = @as([]const u8, spec.meta.id);
    }

    const RtcType = findRtcReaderType(spec);
    const LedType = findPeripheralType(spec, .led);
    const LedStripType = findPeripheralType(spec, .led_strip);
    const DisplayType = findPeripheralType(spec, .display);
    const MicType = findPeripheralType(spec, .mic);
    const SpeakerType = findPeripheralType(spec, .speaker);
    const AudioSystemType = findPeripheralType(spec, .audio_system);
    const TempSensorType = findPeripheralType(spec, .temp_sensor);
    const ImuType = findPeripheralType(spec, .imu);
    const GpioType = findPeripheralType(spec, .gpio);
    const AdcType = findPeripheralType(spec, .adc);
    const PwmType = findPeripheralType(spec, .pwm);
    const I2cType = findPeripheralType(spec, .i2c);
    const SpiType = findPeripheralType(spec, .spi);
    const UartType = findPeripheralType(spec, .uart);
    const WifiType = findPeripheralType(spec, .wifi);
    const BleType = findPeripheralType(spec, .ble);
    const HciType = findPeripheralType(spec, .hci);
    const KvsType = findPeripheralType(spec, .kvs);

    comptime {
        validatePeripheralType(RtcType, .rtc);
        validatePeripheralType(LedType, .led);
        validatePeripheralType(LedStripType, .led_strip);
        validatePeripheralType(DisplayType, .display);
        validatePeripheralType(MicType, .mic);
        validatePeripheralType(SpeakerType, .speaker);
        validatePeripheralType(AudioSystemType, .audio_system);
        validatePeripheralType(TempSensorType, .temp_sensor);
        validatePeripheralType(ImuType, .imu);
        validatePeripheralType(GpioType, .gpio);
        validatePeripheralType(AdcType, .adc);
        validatePeripheralType(PwmType, .pwm);
        validatePeripheralType(I2cType, .i2c);
        validatePeripheralType(SpiType, .spi);
        validatePeripheralType(UartType, .uart);
        validatePeripheralType(WifiType, .wifi);
        validatePeripheralType(BleType, .ble);
        validatePeripheralType(HciType, .hci);
        validatePeripheralType(KvsType, .kvs);
    }

    const RtcDriverType = driverTypeOf(RtcType);
    const LedDriverType = driverTypeOf(LedType);
    const LedStripDriverType = driverTypeOf(LedStripType);
    const DisplayDriverType = driverTypeOf(DisplayType);
    const MicDriverType = driverTypeOf(MicType);
    const SpeakerDriverType = driverTypeOf(SpeakerType);
    const AudioSystemDriverType = driverTypeOf(AudioSystemType);
    const TempSensorDriverType = driverTypeOf(TempSensorType);
    const ImuDriverType = driverTypeOf(ImuType);
    const GpioDriverType = driverTypeOf(GpioType);
    const AdcDriverType = driverTypeOf(AdcType);
    const PwmDriverType = driverTypeOf(PwmType);
    const I2cDriverType = driverTypeOf(I2cType);
    const SpiDriverType = driverTypeOf(SpiType);
    const UartDriverType = driverTypeOf(UartType);
    const WifiDriverType = driverTypeOf(WifiType);
    const BleDriverType = driverTypeOf(BleType);
    const HciDriverType = driverTypeOf(HciType);
    const KvsDriverType = driverTypeOf(KvsType);

    const HasLed = LedType != void;
    const HasLedStrip = LedStripType != void;
    const HasDisplay = DisplayType != void;
    const HasMic = MicType != void;
    const HasSpeaker = SpeakerType != void;
    const HasAudioSystem = AudioSystemType != void;
    const HasTempSensor = TempSensorType != void;
    const HasImu = ImuType != void;
    const HasGpio = GpioType != void;
    const HasAdc = AdcType != void;
    const HasPwm = PwmType != void;
    const HasI2c = I2cType != void;
    const HasSpi = SpiType != void;
    const HasUart = UartType != void;
    const HasWifi = WifiType != void;
    const HasBle = BleType != void;
    const HasHci = HciType != void;
    const HasKvs = KvsType != void;

    const has_led_strip_clear = comptime HasLedStrip and @hasDecl(LedStripType, "clear");
    const has_led_off = comptime HasLed and @hasDecl(LedType, "off");
    const has_rtc_now = comptime @hasDecl(RtcType, "now");

    return struct {
        const Self = @This();

        pub const meta = spec.meta;

        pub const log = if (@hasDecl(spec, "log")) spec.log else void;
        pub const time = if (@hasDecl(spec, "time")) spec.time else void;
        pub const thread = if (@hasDecl(spec, "thread")) spec.thread else void;
        pub const allocator = if (@hasDecl(spec, "allocator")) spec.allocator else void;
        pub const fs = if (@hasDecl(spec, "fs")) spec.fs else void;
        pub const isRunning = if (@hasDecl(spec, "isRunning"))
            spec.isRunning
        else
            struct {
                fn always() bool {
                    return true;
                }
            }.always;

        pub const rtc = RtcType;
        pub const led = LedType;
        pub const led_strip = LedStripType;
        pub const display = DisplayType;
        pub const mic = MicType;
        pub const speaker = SpeakerType;
        pub const audio_system = AudioSystemType;
        pub const temp_sensor = TempSensorType;
        pub const imu = ImuType;
        pub const gpio = GpioType;
        pub const adc = AdcType;
        pub const pwm = PwmType;
        pub const i2c = I2cType;
        pub const spi = SpiType;
        pub const uart = UartType;
        pub const wifi = WifiType;
        pub const ble = BleType;
        pub const hci = HciType;
        pub const kvs = KvsType;

        rtc_driver: RtcDriverType,
        rtc_dev: RtcType,
        init_rtc: bool = false,

        led_driver: if (HasLed) LedDriverType else void,
        led_dev: if (HasLed) LedType else void,
        init_led: bool = false,

        led_strip_driver: if (HasLedStrip) LedStripDriverType else void,
        led_strip_dev: if (HasLedStrip) LedStripType else void,
        init_led_strip: bool = false,

        display_driver: if (HasDisplay) DisplayDriverType else void,
        display_dev: if (HasDisplay) DisplayType else void,
        init_display: bool = false,

        mic_driver: if (HasMic) MicDriverType else void,
        mic_dev: if (HasMic) MicType else void,
        init_mic: bool = false,

        speaker_driver: if (HasSpeaker) SpeakerDriverType else void,
        speaker_dev: if (HasSpeaker) SpeakerType else void,
        init_speaker: bool = false,

        audio_system_driver: if (HasAudioSystem) AudioSystemDriverType else void,
        audio_system_dev: if (HasAudioSystem) AudioSystemType else void,
        init_audio_system: bool = false,

        temp_sensor_driver: if (HasTempSensor) TempSensorDriverType else void,
        temp_sensor_dev: if (HasTempSensor) TempSensorType else void,
        init_temp_sensor: bool = false,

        imu_driver: if (HasImu) ImuDriverType else void,
        imu_dev: if (HasImu) ImuType else void,
        init_imu: bool = false,

        gpio_driver: if (HasGpio) GpioDriverType else void,
        gpio_dev: if (HasGpio) GpioType else void,
        init_gpio: bool = false,

        adc_driver: if (HasAdc) AdcDriverType else void,
        adc_dev: if (HasAdc) AdcType else void,
        init_adc: bool = false,

        pwm_driver: if (HasPwm) PwmDriverType else void,
        pwm_dev: if (HasPwm) PwmType else void,
        init_pwm: bool = false,

        i2c_driver: if (HasI2c) I2cDriverType else void,
        i2c_dev: if (HasI2c) I2cType else void,
        init_i2c: bool = false,

        spi_driver: if (HasSpi) SpiDriverType else void,
        spi_dev: if (HasSpi) SpiType else void,
        init_spi: bool = false,

        uart_driver: if (HasUart) UartDriverType else void,
        uart_dev: if (HasUart) UartType else void,
        init_uart: bool = false,

        wifi_driver: if (HasWifi) WifiDriverType else void,
        wifi_dev: if (HasWifi) WifiType else void,
        init_wifi: bool = false,

        ble_driver: if (HasBle) BleDriverType else void,
        ble_dev: if (HasBle) BleType else void,
        init_ble: bool = false,

        hci_driver: if (HasHci) HciDriverType else void,
        hci_dev: if (HasHci) HciType else void,
        init_hci: bool = false,

        kvs_driver: if (HasKvs) KvsDriverType else void,
        kvs_dev: if (HasKvs) KvsType else void,
        init_kvs: bool = false,

        pub fn init(self: *Self) !void {
            self.init_rtc = false;
            self.init_led = false;
            self.init_led_strip = false;
            self.init_display = false;
            self.init_mic = false;
            self.init_speaker = false;
            self.init_audio_system = false;
            self.init_temp_sensor = false;
            self.init_imu = false;
            self.init_gpio = false;
            self.init_adc = false;
            self.init_pwm = false;
            self.init_i2c = false;
            self.init_spi = false;
            self.init_uart = false;
            self.init_wifi = false;
            self.init_ble = false;
            self.init_hci = false;
            self.init_kvs = false;

            errdefer self.deinit();

            self.rtc_driver = try driverInit(RtcDriverType);
            self.rtc_dev = RtcType.init(&self.rtc_driver);
            self.init_rtc = true;

            if (HasLed) {
                self.led_driver = try driverInit(LedDriverType);
                self.led_dev = LedType.init(&self.led_driver);
                self.init_led = true;
            }

            if (HasLedStrip) {
                self.led_strip_driver = try driverInit(LedStripDriverType);
                self.led_strip_dev = LedStripType.init(&self.led_strip_driver);
                self.init_led_strip = true;
            }

            if (HasDisplay) {
                self.display_driver = try driverInit(DisplayDriverType);
                self.display_dev = DisplayType.init(&self.display_driver);
                self.init_display = true;
            }

            if (HasMic) {
                self.mic_driver = try driverInit(MicDriverType);
                self.mic_dev = MicType.init(&self.mic_driver);
                self.init_mic = true;
            }

            if (HasSpeaker) {
                self.speaker_driver = try driverInit(SpeakerDriverType);
                self.speaker_dev = SpeakerType.init(&self.speaker_driver);
                self.init_speaker = true;
            }

            if (HasAudioSystem) {
                self.audio_system_driver = try driverInit(AudioSystemDriverType);
                self.audio_system_dev = AudioSystemType.init(&self.audio_system_driver);
                self.init_audio_system = true;
            }

            if (HasTempSensor) {
                self.temp_sensor_driver = try driverInit(TempSensorDriverType);
                self.temp_sensor_dev = TempSensorType.init(&self.temp_sensor_driver);
                self.init_temp_sensor = true;
            }

            if (HasImu) {
                self.imu_driver = try driverInit(ImuDriverType);
                self.imu_dev = ImuType.init(&self.imu_driver);
                self.init_imu = true;
            }

            if (HasGpio) {
                self.gpio_driver = try driverInit(GpioDriverType);
                self.gpio_dev = GpioType.init(&self.gpio_driver);
                self.init_gpio = true;
            }

            if (HasAdc) {
                self.adc_driver = try driverInit(AdcDriverType);
                self.adc_dev = AdcType.init(&self.adc_driver);
                self.init_adc = true;
            }

            if (HasPwm) {
                self.pwm_driver = try driverInit(PwmDriverType);
                self.pwm_dev = PwmType.init(&self.pwm_driver);
                self.init_pwm = true;
            }

            if (HasI2c) {
                self.i2c_driver = try driverInit(I2cDriverType);
                self.i2c_dev = I2cType.init(&self.i2c_driver);
                self.init_i2c = true;
            }

            if (HasSpi) {
                self.spi_driver = try driverInit(SpiDriverType);
                self.spi_dev = SpiType.init(&self.spi_driver);
                self.init_spi = true;
            }

            if (HasUart) {
                self.uart_driver = try driverInit(UartDriverType);
                self.uart_dev = UartType.init(&self.uart_driver);
                self.init_uart = true;
            }

            if (HasWifi) {
                self.wifi_driver = try driverInit(WifiDriverType);
                self.wifi_dev = WifiType.init(&self.wifi_driver);
                self.init_wifi = true;
            }

            if (HasBle) {
                self.ble_driver = try driverInit(BleDriverType);
                self.ble_dev = BleType.init(&self.ble_driver);
                self.init_ble = true;
            }

            if (HasHci) {
                self.hci_driver = try driverInit(HciDriverType);
                self.hci_dev = HciType.init(&self.hci_driver);
                self.init_hci = true;
            }

            if (HasKvs) {
                self.kvs_driver = try driverInit(KvsDriverType);
                self.kvs_dev = KvsType.init(&self.kvs_driver);
                self.init_kvs = true;
            }
        }

        pub fn deinit(self: *Self) void {
            if (HasKvs and self.init_kvs) {
                driverDeinit(KvsDriverType, &self.kvs_driver);
                self.init_kvs = false;
            }
            if (HasHci and self.init_hci) {
                driverDeinit(HciDriverType, &self.hci_driver);
                self.init_hci = false;
            }
            if (HasBle and self.init_ble) {
                driverDeinit(BleDriverType, &self.ble_driver);
                self.init_ble = false;
            }
            if (HasWifi and self.init_wifi) {
                driverDeinit(WifiDriverType, &self.wifi_driver);
                self.init_wifi = false;
            }
            if (HasUart and self.init_uart) {
                driverDeinit(UartDriverType, &self.uart_driver);
                self.init_uart = false;
            }
            if (HasSpi and self.init_spi) {
                driverDeinit(SpiDriverType, &self.spi_driver);
                self.init_spi = false;
            }
            if (HasI2c and self.init_i2c) {
                driverDeinit(I2cDriverType, &self.i2c_driver);
                self.init_i2c = false;
            }
            if (HasPwm and self.init_pwm) {
                driverDeinit(PwmDriverType, &self.pwm_driver);
                self.init_pwm = false;
            }
            if (HasAdc and self.init_adc) {
                driverDeinit(AdcDriverType, &self.adc_driver);
                self.init_adc = false;
            }
            if (HasGpio and self.init_gpio) {
                driverDeinit(GpioDriverType, &self.gpio_driver);
                self.init_gpio = false;
            }
            if (HasImu and self.init_imu) {
                driverDeinit(ImuDriverType, &self.imu_driver);
                self.init_imu = false;
            }
            if (HasTempSensor and self.init_temp_sensor) {
                driverDeinit(TempSensorDriverType, &self.temp_sensor_driver);
                self.init_temp_sensor = false;
            }
            if (HasAudioSystem and self.init_audio_system) {
                driverDeinit(AudioSystemDriverType, &self.audio_system_driver);
                self.init_audio_system = false;
            }
            if (HasSpeaker and self.init_speaker) {
                driverDeinit(SpeakerDriverType, &self.speaker_driver);
                self.init_speaker = false;
            }
            if (HasMic and self.init_mic) {
                driverDeinit(MicDriverType, &self.mic_driver);
                self.init_mic = false;
            }
            if (HasDisplay and self.init_display) {
                driverDeinit(DisplayDriverType, &self.display_driver);
                self.init_display = false;
            }
            if (HasLedStrip and self.init_led_strip) {
                if (comptime has_led_strip_clear) {
                    self.led_strip_dev.clear();
                }
                driverDeinit(LedStripDriverType, &self.led_strip_driver);
                self.init_led_strip = false;
            }
            if (HasLed and self.init_led) {
                if (comptime has_led_off) {
                    self.led_dev.off();
                }
                driverDeinit(LedDriverType, &self.led_driver);
                self.init_led = false;
            }
            if (self.init_rtc) {
                driverDeinit(RtcDriverType, &self.rtc_driver);
                self.init_rtc = false;
            }
        }

        pub fn uptime(self: *Self) u64 {
            return self.rtc_dev.uptime();
        }

        pub fn now(self: *Self) ?rtc_mod.Timestamp {
            if (comptime has_rtc_now) {
                return self.rtc_dev.now();
            }
            return null;
        }
    };
}

pub fn from(comptime spec: type) type {
    return Board(spec);
}
