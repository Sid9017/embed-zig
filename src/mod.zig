pub const runtime = struct {
    pub const errors = @import("runtime/errors.zig");
    pub const sync = struct {
        pub const mutex = @import("runtime/sync/mutex.zig");
        pub const condition = @import("runtime/sync/condition.zig");
        pub const notify = @import("runtime/sync/notify.zig");

        pub const Mutex = mutex.Mutex;
        pub const isMutex = mutex.is;
        pub const Condition = condition.Condition;
        pub const isCondition = condition.is;
        pub const Notify = notify.Notify;
        pub const isNotify = notify.is;
    };
    pub const time = @import("runtime/time.zig");
    pub const thread = @import("runtime/thread.zig");
    pub const system = @import("runtime/system.zig");
    pub const channel_factory = @import("runtime/channel_factory.zig");
    pub const socket = @import("runtime/socket.zig");
    pub const fs = @import("runtime/fs.zig");
    pub const log = @import("runtime/log.zig");
    pub const rng = @import("runtime/rng.zig");
    pub const ota_backend = @import("runtime/ota_backend.zig");
    pub const std = @import("runtime/std.zig");

    pub const test_runners = struct {
        pub const channel = @import("runtime/channel_test_runner.zig");
    };

    pub const crypto = struct {
        pub const hash = @import("runtime/crypto/hash.zig");
        pub const hmac = @import("runtime/crypto/hmac.zig");
        pub const hkdf = @import("runtime/crypto/hkdf.zig");
        pub const aead = @import("runtime/crypto/aead.zig");
        pub const pki = @import("runtime/crypto/pki.zig");
        pub const suite = @import("runtime/crypto/suite.zig");
    };
};

pub const hal = struct {
    pub const marker = @import("hal/marker.zig");
    pub const board = @import("hal/board.zig");
    pub const gpio = @import("hal/gpio.zig");
    pub const adc = @import("hal/adc.zig");
    pub const pwm = @import("hal/pwm.zig");
    pub const i2c = @import("hal/i2c.zig");
    pub const i2s = @import("hal/i2s.zig");
    pub const spi = @import("hal/spi.zig");
    pub const uart = @import("hal/uart.zig");
    pub const wifi = @import("hal/wifi.zig");
    pub const hci = @import("hal/hci.zig");
    pub const kvs = @import("hal/kvs.zig");
    pub const rtc = @import("hal/rtc.zig");
    pub const led = @import("hal/led.zig");
    pub const led_strip = @import("hal/led_strip.zig");
    pub const display = @import("hal/display.zig");
    pub const speaker = @import("hal/speaker.zig");
    pub const mic = @import("hal/mic.zig");
    pub const audio_system = @import("hal/audio_system.zig");
    pub const temp_sensor = @import("hal/temp_sensor.zig");
    pub const imu = @import("hal/imu.zig");
};

pub const pkg = struct {
    pub const audio = struct {
        pub const engine = @import("pkg/audio/engine.zig");
        pub const mixer = @import("pkg/audio/mixer.zig");
        pub const override_buffer = @import("pkg/audio/override_buffer.zig");
        pub const resampler = @import("pkg/audio/resampler.zig");

        pub const Engine = engine.Engine;
        pub const Mixer = mixer.Mixer;
        pub const Format = resampler.Format;
        pub const Beamformer = engine.Beamformer;
        pub const Processor = engine.Processor;
        pub const PassthroughBeamformer = engine.PassthroughBeamformer;
        pub const PassthroughProcessor = engine.PassthroughProcessor;
    };

    pub const ble = struct {
        pub const gatt = struct {
            pub const server = @import("pkg/ble/gatt/server.zig");
            pub const client = @import("pkg/ble/gatt/client.zig");
        };

        pub const host = struct {
            pub const host_mod = @import("pkg/ble/host/host.zig");
            pub const Host = host_mod.Host;
            pub const hci = struct {
                pub const hci = @import("pkg/ble/host/hci/hci.zig");
                pub const acl = @import("pkg/ble/host/hci/acl.zig");
                pub const commands = @import("pkg/ble/host/hci/commands.zig");
                pub const events = @import("pkg/ble/host/hci/events.zig");
            };
            pub const att = struct {
                pub const att = @import("pkg/ble/host/att/att.zig");
            };
            pub const gap = struct {
                pub const gap = @import("pkg/ble/host/gap/gap.zig");
            };
            pub const l2cap = struct {
                pub const l2cap = @import("pkg/ble/host/l2cap/l2cap.zig");
            };
        };

        pub const xfer = @import("pkg/ble/xfer/api.zig");
        pub const term = @import("pkg/ble/term/api.zig");

        pub const hci = host.hci;
        pub const att = host.att;
        pub const gap = host.gap;
        pub const l2cap = host.l2cap;
    };

    pub const drivers = struct {
        pub const es7210 = @import("pkg/drivers/es7210/src.zig");
        pub const es8311 = @import("pkg/drivers/es8311/src.zig");
        pub const qmi8658 = @import("pkg/drivers/qmi8658/src.zig");
        pub const tca9554 = @import("pkg/drivers/tca9554/src.zig");
    };

    pub const event = struct {
        pub const types = @import("pkg/event/types.zig");
        pub const bus = @import("pkg/event/bus.zig");
        pub const ring_buffer = @import("pkg/event/ring_buffer.zig");

        pub const PeriphEvent = types.PeriphEvent;
        pub const CustomEvent = types.CustomEvent;
        pub const TimerEvent = types.TimerEvent;
        pub const SystemEvent = types.SystemEvent;
        pub const Bus = bus.Bus;
        pub const EventInjector = bus.EventInjector;
        pub const RingBuffer = ring_buffer.RingBuffer;

        pub const button = struct {
            pub const events = @import("pkg/event/button/event.zig");
            pub const gesture = @import("pkg/event/button/gesture.zig");

            pub const RawEvent = events.RawEvent;
            pub const RawEventCode = events.RawEventCode;
            pub const GestureEvent = events.GestureEvent;
            pub const ButtonGesture = gesture.ButtonGesture;
            pub const GestureConfig = gesture.GestureConfig;

            pub const gpio = struct {
                const button_mod = @import("pkg/event/button/gpio/button.zig");
                pub const GpioButton = button_mod.Button;
            };

            pub const adc = struct {
                const adc_button_mod = @import("pkg/event/button/adc/button.zig");
                pub const AdcButtonSet = adc_button_mod.AdcButtonSet;
                pub const AdcButtonConfig = adc_button_mod.Config;
            };

            pub const GpioButton = gpio.GpioButton;
            pub const AdcButtonSet = adc.AdcButtonSet;
            pub const AdcButtonConfig = adc.AdcButtonConfig;
        };

        pub const motion = struct {
            pub const motion = @import("pkg/event/motion/motion.zig");
            pub const detector = @import("pkg/event/motion/detector.zig");
            pub const types = @import("pkg/event/motion/types.zig");
            pub const peripheral = @import("pkg/event/motion/peripheral.zig");
            const motion_mod = @import("pkg/event/motion/motion.zig");
            const detector_mod = @import("pkg/event/motion/detector.zig");
            const peripheral_mod = @import("pkg/event/motion/peripheral.zig");

            pub const MotionAction = motion_mod.MotionAction;
            pub const Detector = detector_mod.Detector;
            pub const MotionPeripheral = peripheral_mod.MotionPeripheral;
        };
    };

    pub const flux = struct {
        pub const store = @import("pkg/flux/store.zig");
        pub const app_state_manager = @import("pkg/flux/app_state_manager.zig");
        pub const Store = store.Store;
        pub const AppStateManager = app_state_manager.AppStateManager;
    };

    pub const net = struct {
        pub const conn = @import("pkg/net/conn.zig");
        pub const Conn = conn.from;
        pub const SocketConn = conn.SocketConn;

        pub const dns = @import("pkg/net/dns/dns.zig");
        pub const ntp = @import("pkg/net/ntp/ntp.zig");
        pub const url = @import("pkg/net/url/url.zig");
        pub const ws = struct {
            pub const frame = @import("pkg/net/ws/frame.zig");
            pub const handshake = @import("pkg/net/ws/handshake.zig");
            pub const client = @import("pkg/net/ws/client.zig");
            pub const sha1 = @import("pkg/net/ws/sha1.zig");
            pub const base64 = @import("pkg/net/ws/base64.zig");

            pub const Client = client.Client;
            pub const Message = client.Message;
            pub const MessageType = client.MessageType;
            pub const copyForward = client.copyForward;
        };

        pub const tls = struct {
            pub const common = @import("pkg/net/tls/common.zig");
            pub const record = @import("pkg/net/tls/record.zig");
            pub const handshake = @import("pkg/net/tls/handshake.zig");
            pub const alert = @import("pkg/net/tls/alert.zig");
            pub const extensions = @import("pkg/net/tls/extensions.zig");
            pub const client = @import("pkg/net/tls/client.zig");
            pub const stream = @import("pkg/net/tls/stream.zig");
            pub const kdf = @import("pkg/net/tls/kdf.zig");
            pub const cert = @import("pkg/net/tls/cert/certs.zig");

            pub const Client = client.Client;
            pub const Stream = stream.Stream;
            pub const connect = client.connect;
        };

        pub const http = struct {
            pub const transport = @import("pkg/net/http/transport.zig");
            pub const client = @import("pkg/net/http/client.zig");
            pub const request = @import("pkg/net/http/request.zig");
            pub const response = @import("pkg/net/http/response.zig");
            pub const router = @import("pkg/net/http/router.zig");
            pub const static = @import("pkg/net/http/static.zig");
            pub const server_mod = @import("pkg/net/http/server.zig");
        };
    };

    pub const ui = struct {
        pub const render = struct {
            pub const framebuffer = @import("pkg/ui/render/framebuffer/framebuffer.zig");
            pub const fb_font = @import("pkg/ui/render/framebuffer/font.zig");
            pub const image = @import("pkg/ui/render/framebuffer/image.zig");
            pub const dirty = @import("pkg/ui/render/framebuffer/dirty.zig");
            pub const anim = @import("pkg/ui/render/framebuffer/anim.zig");
            pub const scene = @import("pkg/ui/render/framebuffer/scene.zig");

            pub const ttf_font = @import("pkg/ui/render/framebuffer/ttf_font.zig");

            pub const Framebuffer = framebuffer.Framebuffer;
            pub const ColorFormat = framebuffer.ColorFormat;
            pub const BitmapFont = fb_font.BitmapFont;
            pub const TtfFont = ttf_font.TtfFont;
            pub const asciiLookup = fb_font.asciiLookup;
            pub const decodeUtf8 = fb_font.decodeUtf8;
            pub const Image = image.Image;
            pub const Rect = dirty.Rect;
            pub const DirtyTracker = dirty.DirtyTracker;
            pub const AnimPlayer = anim.AnimPlayer;
            pub const AnimFrame = anim.AnimFrame;
            pub const blitAnimFrame = anim.blitAnimFrame;
            pub const Compositor = scene.Compositor;
            pub const Region = scene.Region;
            pub const SceneRenderer = scene.SceneRenderer;
        };

        pub const font = @import("pkg/ui/render/font/api.zig");
        pub const led_strip = struct {
            pub const frame = @import("pkg/ui/led_strip/frame.zig");
            pub const animator = @import("pkg/ui/led_strip/animator.zig");
            pub const transition = @import("pkg/ui/led_strip/transition.zig");

            pub const Frame = frame.Frame;
            pub const Color = frame.Color;
            pub const Animator = animator.Animator;
        };
    };

    pub const cellular = struct {
        pub const types = @import("pkg/cellular/types.zig");
        pub const cellular_mod = @import("pkg/cellular/cellular.zig");
        pub const voice = @import("pkg/cellular/voice.zig");
        pub const apn = @import("pkg/cellular/apn.zig");
        pub const io = struct {
            pub const io_mod = @import("pkg/cellular/io/io.zig");
            pub const trace = @import("pkg/cellular/io/trace.zig");
            pub const mock = @import("pkg/cellular/io/mock.zig");
        };
        pub const at = struct {
            pub const engine = @import("pkg/cellular/at/engine.zig");
            pub const commands = @import("pkg/cellular/at/commands.zig");
            pub const parse = @import("pkg/cellular/at/parse.zig");
            pub const cmux = @import("pkg/cellular/at/cmux.zig");
            pub const urcs = @import("pkg/cellular/at/urcs.zig");
        };
        pub const modem = struct {
            pub const modem_mod = @import("pkg/cellular/modem/modem.zig");
            pub const sim = @import("pkg/cellular/modem/sim.zig");
            pub const signal = @import("pkg/cellular/modem/signal.zig");
            pub const quectel = @import("pkg/cellular/modem/quectel.zig");
            pub const simcom = @import("pkg/cellular/modem/simcom.zig");
            pub const quectel_stub = @import("pkg/cellular/modem/quectel_stub.zig");
        };
    };

    pub const app = @import("pkg/app/app_runtime.zig");
};

pub const third_party = struct {
    pub const portaudio = @import("third_party/portaudio/src.zig");
    pub const speexdsp = @import("third_party/speexdsp/src.zig");
    pub const opus = @import("third_party/opus/src.zig");
    pub const ogg = @import("third_party/ogg/src.zig");
    pub const stb_truetype = @import("third_party/stb_truetype/src.zig");
    pub const fonts = @import("third_party/fonts/mod.zig");
};

pub const websim = struct {
    pub const server = @import("websim/server.zig");
    pub const remote_hal = @import("websim/remote_hal.zig");
    pub const ws = @import("websim/ws.zig");
    pub const outbox = @import("websim/outbox.zig");
    pub const yaml_case = @import("websim/yaml_case.zig");
    pub const test_runner = @import("websim/test_runner.zig");

    pub const RemoteHal = remote_hal.RemoteHal;
    pub const Outbox = outbox.Outbox;
    pub const DevRouter = outbox.DevRouter;
    pub const serve = server.serve;
    pub const ServeOptions = server.ServeOptions;
    pub const runTestDir = test_runner.runTestDir;

    pub const hal = struct {
        pub const gpio = @import("websim/hal/gpio.zig");
        pub const led_strip = @import("websim/hal/led_strip.zig");
        pub const rtc = @import("websim/hal/rtc.zig");
        pub const display = @import("websim/hal/display.zig");

        pub const Gpio = gpio.Gpio;
        pub const LedStrip = led_strip.LedStrip;
        pub const Rtc = rtc.Rtc;
        pub const Display = display.Display;
    };
};

test {
    @import("std").testing.refAllDecls(@This());
}
