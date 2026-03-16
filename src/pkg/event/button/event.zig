//! Shared button event types for GPIO/ADC buttons and gesture recognition.

pub const RawEventCode = enum(u16) {
    press = 1,
    release = 2,
};

pub const RawEvent = struct {
    id: []const u8 = "",
    code: RawEventCode,
};

pub const GestureEvent = struct {
    id: []const u8 = "",
    gesture: Gesture,

    pub const Gesture = union(enum) {
        click: u16,
        long_press: u32,
    };
};
