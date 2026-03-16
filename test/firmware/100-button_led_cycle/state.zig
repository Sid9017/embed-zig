const embed = @import("embed");
const event = embed.pkg.event;
const button = event.button;
const led = embed.pkg.ui.led_strip;

pub const Color = led.Color;
pub const Frame = led.Frame(1);
pub const LedAnim = led.Animator(1, 4);

pub const State = struct {
    led: LedAnim = .{},
};

const click_colors = [_]Color{ Color.red, Color.green, Color.blue, Color.white };

fn transitionTo(state: *State, target: Frame) void {
    const prev = state.led.current;
    state.led = LedAnim.fixed(target);
    state.led.current = prev;
}

pub fn reduce(state: *State, ev: button.GestureEvent) void {
    switch (ev.gesture) {
        .click => |count| {
            if (count > 0 and count <= click_colors.len) {
                transitionTo(state, Frame.solid(click_colors[count - 1]));
            }
        },
        .long_press => {
            const target = if (@import("std").meta.eql(state.led.current.pixels[0], Color.black))
                Color.white
            else
                Color.black;
            transitionTo(state, Frame.solid(target));
        },
    }
}
