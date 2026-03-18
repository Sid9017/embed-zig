const std = @import("std");
const testing = std.testing;

const embed = @import("embed");
const scene = embed.pkg.ui.render.scene;
const Dirty = embed.pkg.ui.render.dirty;
const framebuffer = embed.pkg.ui.render.framebuffer;

const TestFB = framebuffer.Framebuffer(240, 240, .rgb565);

const GameState = struct {
    score: u32 = 0,
    player_x: u16 = 110,
    obstacle_y: u16 = 50,
    time_sec: u16 = 0,
};

const HudScore = struct {
    const bg: u16 = 0x2104;

    pub fn bounds(_: *const GameState) Dirty.Rect {
        return .{ .x = 0, .y = 0, .w = 240, .h = 20 };
    }

    pub fn changed(s: *const GameState, p: *const GameState) bool {
        return s.score != p.score;
    }

    pub fn draw(fb: *TestFB, s: *const GameState) void {
        fb.fillRect(0, 0, 240, 20, bg);
        const digit_x: u16 = 60 + @as(u16, @intCast(@min(s.score, 999) % 10)) * 0;
        _ = digit_x;
        fb.fillRect(60, 4, 40, 12, 0xFFFF);
    }
};

const HudTimer = struct {
    const bg: u16 = 0x2104;

    pub fn bounds(_: *const GameState) Dirty.Rect {
        return .{ .x = 180, .y = 0, .w = 60, .h = 20 };
    }

    pub fn changed(s: *const GameState, p: *const GameState) bool {
        return s.time_sec != p.time_sec;
    }

    pub fn draw(fb: *TestFB, _: *const GameState) void {
        fb.fillRect(180, 0, 60, 20, bg);
        fb.fillRect(190, 4, 40, 12, 0xFFFF);
    }
};

const PlayerCar = struct {
    const bg: u16 = 0x0000;

    pub fn bounds(s: *const GameState) Dirty.Rect {
        return .{ .x = s.player_x, .y = 180, .w = 30, .h = 45 };
    }

    pub fn changed(s: *const GameState, p: *const GameState) bool {
        return s.player_x != p.player_x;
    }

    pub fn draw(fb: *TestFB, s: *const GameState) void {
        fb.fillRoundRect(s.player_x, 180, 30, 45, 5, 0xF800);
    }
};

const Obstacles = struct {
    const bg: u16 = 0x0000;

    pub fn bounds(_: *const GameState) Dirty.Rect {
        return .{ .x = 40, .y = 20, .w = 160, .h = 160 };
    }

    pub fn changed(s: *const GameState, p: *const GameState) bool {
        return s.obstacle_y != p.obstacle_y;
    }

    pub fn draw(fb: *TestFB, s: *const GameState) void {
        fb.fillRect(40, 20, 160, 160, 0x4208);
        fb.fillRoundRect(80, s.obstacle_y, 25, 35, 4, 0x07E0);
        fb.fillRoundRect(140, s.obstacle_y + 50, 25, 35, 4, 0x07E0);
    }
};

const Game = scene.Compositor(TestFB, GameState, .{ HudScore, HudTimer, PlayerCar, Obstacles });

test "Compositor: first frame draws all" {
    var fb = TestFB.init(0);
    const s = GameState{};
    const n = Game.render(&fb, &s, &s, true);
    try testing.expectEqual(@as(u8, 4), n);
}

test "Compositor: no change = no redraw" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    const s = GameState{ .score = 50 };
    const n = Game.render(&fb, &s, &s, false);
    try testing.expectEqual(@as(u8, 0), n);
    try testing.expectEqual(@as(usize, 0), fb.getDirtyRects().len);
}

test "Compositor: score change redraws only HudScore" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    const prev = GameState{ .score = 10 };
    const curr = GameState{ .score = 11 };
    const n = Game.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u8, 1), n);

    var dirty: u32 = 0;
    for (fb.getDirtyRects()) |r| dirty += r.area();
    try testing.expect(dirty <= 240 * 20);
}

test "Compositor: timer change redraws only HudTimer" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    const prev = GameState{ .time_sec = 30 };
    const curr = GameState{ .time_sec = 31 };
    const n = Game.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u8, 1), n);

    var dirty: u32 = 0;
    for (fb.getDirtyRects()) |r| dirty += r.area();
    try testing.expect(dirty <= 60 * 20);
}

test "Compositor: player move clears old + draws new" {
    var fb = TestFB.init(0);
    const s0 = GameState{ .player_x = 100 };
    _ = Game.render(&fb, &s0, &s0, true);

    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(115, 200));

    fb.clearDirty();
    const s1 = GameState{ .player_x = 150 };
    const n = Game.render(&fb, &s1, &s0, false);
    try testing.expectEqual(@as(u8, 1), n);

    try testing.expectEqual(@as(u16, 0x0000), fb.getPixel(115, 200));
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(165, 200));
}

test "Compositor: score + player redraws 2 components" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    const prev = GameState{ .score = 10, .player_x = 100 };
    const curr = GameState{ .score = 20, .player_x = 120 };
    const n = Game.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u8, 2), n);
}

test "Compositor: count" {
    try testing.expectEqual(@as(usize, 4), Game.count());
}

const EdgeState = struct {
    x: u16 = 0,
    visible: bool = true,
};

const EdgeSprite = struct {
    const bg: u16 = 0x0000;
    pub fn bounds(s: *const EdgeState) Dirty.Rect {
        return .{ .x = s.x, .y = 220, .w = 30, .h = 30 };
    }
    pub fn changed(s: *const EdgeState, p: *const EdgeState) bool {
        return s.x != p.x or s.visible != p.visible;
    }
    pub fn draw(fb: *TestFB, s: *const EdgeState) void {
        if (s.visible) {
            fb.fillRect(s.x, 220, 30, 30, 0xF800);
        }
    }
};

const EdgeScene = scene.Compositor(TestFB, EdgeState, .{EdgeSprite});

test "edge: component partially off-screen right" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    const prev = EdgeState{ .x = 100 };
    const curr = EdgeState{ .x = 225 };
    const n = EdgeScene.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u8, 1), n);
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(225, 225));
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(239, 225));
    try testing.expectEqual(@as(u16, 0x0000), fb.getPixel(110, 230));
}

test "edge: component moves from off-screen to on-screen" {
    var fb = TestFB.init(0x1111);
    const prev = EdgeState{ .x = 250 };
    const curr = EdgeState{ .x = 200 };
    const n = EdgeScene.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u8, 1), n);
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(210, 230));
}

test "edge: component visibility toggle" {
    var fb = TestFB.init(0);
    const s0 = EdgeState{ .x = 50, .visible = true };
    _ = EdgeScene.render(&fb, &s0, &s0, true);
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(60, 230));

    fb.clearDirty();
    const s1 = EdgeState{ .x = 50, .visible = false };
    _ = EdgeScene.render(&fb, &s1, &s0, false);
    try testing.expectEqual(@as(u16, 0x0000), fb.getPixel(60, 230));
}

const OverlapState = struct {
    bg_color: u16 = 0x1111,
    fg_value: u16 = 0xF800,
};

const BackPanel = struct {
    const bg: u16 = 0x0000;
    pub fn bounds(_: *const OverlapState) Dirty.Rect {
        return .{ .x = 50, .y = 50, .w = 100, .h = 100 };
    }
    pub fn changed(s: *const OverlapState, p: *const OverlapState) bool {
        return s.bg_color != p.bg_color;
    }
    pub fn draw(fb: *TestFB, s: *const OverlapState) void {
        fb.fillRect(50, 50, 100, 100, s.bg_color);
    }
};

const FrontBadge = struct {
    const bg: u16 = 0x1111;
    pub fn bounds(_: *const OverlapState) Dirty.Rect {
        return .{ .x = 80, .y = 80, .w = 40, .h = 40 };
    }
    pub fn changed(s: *const OverlapState, p: *const OverlapState) bool {
        return s.fg_value != p.fg_value;
    }
    pub fn draw(fb: *TestFB, s: *const OverlapState) void {
        fb.fillRect(80, 80, 40, 40, s.fg_value);
    }
};

const OverlapScene = scene.Compositor(TestFB, OverlapState, .{ BackPanel, FrontBadge });

test "edge: overlapping components both drawn on first frame" {
    var fb = TestFB.init(0);
    const s = OverlapState{};
    _ = OverlapScene.render(&fb, &s, &s, true);
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(90, 90));
    try testing.expectEqual(@as(u16, 0x1111), fb.getPixel(55, 55));
}

test "edge: only front changes — back untouched" {
    var fb = TestFB.init(0);
    const s0 = OverlapState{};
    _ = OverlapScene.render(&fb, &s0, &s0, true);

    fb.clearDirty();
    const s1 = OverlapState{ .fg_value = 0x07E0 };
    const n = OverlapScene.render(&fb, &s1, &s0, false);
    try testing.expectEqual(@as(u8, 1), n);
    try testing.expectEqual(@as(u16, 0x07E0), fb.getPixel(90, 90));
    try testing.expectEqual(@as(u16, 0x1111), fb.getPixel(55, 55));
}

test "edge: only back changes — front gets overwritten by clear" {
    var fb = TestFB.init(0);
    const s0 = OverlapState{};
    _ = OverlapScene.render(&fb, &s0, &s0, true);

    fb.clearDirty();
    const s1 = OverlapState{ .bg_color = 0x2222 };
    const n = OverlapScene.render(&fb, &s1, &s0, false);
    try testing.expectEqual(@as(u8, 1), n);
    try testing.expectEqual(@as(u16, 0x2222), fb.getPixel(90, 90));
}

test "edge: rapid back-and-forth movement" {
    var fb = TestFB.init(0);
    const s0 = GameState{ .player_x = 100 };
    _ = Game.render(&fb, &s0, &s0, true);

    fb.clearDirty();
    const s1 = GameState{ .player_x = 120 };
    _ = Game.render(&fb, &s1, &s0, false);
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(135, 200));
    try testing.expectEqual(@as(u16, 0x0000), fb.getPixel(105, 200));

    fb.clearDirty();
    const s2 = GameState{ .player_x = 100 };
    _ = Game.render(&fb, &s2, &s1, false);
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(115, 200));
    try testing.expectEqual(@as(u16, 0x0000), fb.getPixel(135, 200));
}

test "edge: move by 1 pixel" {
    var fb = TestFB.init(0);
    const prev = GameState{ .player_x = 100 };
    const curr = GameState{ .player_x = 101 };
    fb.clearDirty();
    const n = Game.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u8, 1), n);

    var dirty: u32 = 0;
    for (fb.getDirtyRects()) |r| dirty += r.area();
    try testing.expect(dirty <= 30 * 45 * 2);
}

const SingleScene = scene.Compositor(TestFB, GameState, .{HudScore});

test "edge: single component scene" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    const prev = GameState{ .score = 0 };
    const curr = GameState{ .score = 1 };
    const n = SingleScene.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u8, 1), n);
    try testing.expectEqual(@as(usize, 1), SingleScene.count());
}

const NoBgComponent = struct {
    pub fn bounds(_: *const GameState) Dirty.Rect {
        return .{ .x = 10, .y = 10, .w = 20, .h = 20 };
    }
    pub fn changed(s: *const GameState, p: *const GameState) bool {
        return s.score != p.score;
    }
    pub fn draw(fb: *TestFB, _: *const GameState) void {
        fb.fillRect(10, 10, 20, 20, 0xAAAA);
    }
};

const NoBgScene = scene.Compositor(TestFB, GameState, .{NoBgComponent});

test "edge: component without bg declaration uses black" {
    var fb = TestFB.init(0xFFFF);
    fb.clearDirty();
    const prev = GameState{ .score = 0 };
    const curr = GameState{ .score = 1 };
    _ = NoBgScene.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u16, 0xAAAA), fb.getPixel(15, 15));
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(5, 5));
}

test "edge: all 4 components change at once" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    const prev = GameState{ .score = 0, .time_sec = 0, .player_x = 100, .obstacle_y = 50 };
    const curr = GameState{ .score = 99, .time_sec = 60, .player_x = 200, .obstacle_y = 100 };
    const n = Game.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u8, 4), n);

    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(70, 8));
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(200, 8));
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(215, 200));
    try testing.expectEqual(@as(u16, 0x0000), fb.getPixel(115, 200));
}

const PhantomComponent = struct {
    const bg: u16 = 0x0000;
    pub fn bounds(_: *const GameState) Dirty.Rect {
        return .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    }
    pub fn changed(_: *const GameState, _: *const GameState) bool {
        return true;
    }
    pub fn draw(_: *TestFB, _: *const GameState) void {}
};

const PhantomScene = scene.Compositor(TestFB, GameState, .{PhantomComponent});

test "edge: always-dirty component with no-op draw" {
    var fb = TestFB.init(0xBBBB);
    fb.clearDirty();
    const s = GameState{};
    const n = PhantomScene.render(&fb, &s, &s, false);
    try testing.expectEqual(@as(u8, 1), n);
    try testing.expectEqual(@as(u16, 0x0000), fb.getPixel(5, 5));
    try testing.expectEqual(@as(u16, 0xBBBB), fb.getPixel(15, 15));
}

test "edge: consecutive renders accumulate dirty rects" {
    var fb = TestFB.init(0);
    const s0 = GameState{ .score = 0 };
    const s1 = GameState{ .score = 1 };
    _ = Game.render(&fb, &s1, &s0, false);

    const s2 = GameState{ .score = 1, .player_x = 130 };
    _ = Game.render(&fb, &s2, &s1, false);

    var dirty: u32 = 0;
    for (fb.getDirtyRects()) |r| dirty += r.area();
    try testing.expect(dirty > 240 * 20);
}
