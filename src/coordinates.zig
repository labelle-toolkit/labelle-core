/// Coordinate system convention for LaBelle.
///
/// The engine uses a Y-up coordinate system with the origin at bottom-left.
/// Game code always works in Y-up coordinates. Transforms between Y-up (game)
/// and Y-down (screen/render) happen at render and input boundaries only.
///
/// Backend implementations (raylib, sokol, SDL, etc.) use screen coordinates
/// (Y-down, origin at top-left). The helpers below convert between the two.

const position = @import("position.zig");
const Position = position.Position;

/// Which coordinate convention a value is expressed in.
pub const CoordinateSystem = enum {
    /// Game coordinates: origin at bottom-left, Y increases upward.
    /// This is the default for all game logic.
    y_up,

    /// Screen/render coordinates: origin at top-left, Y increases downward.
    /// Used by backends and low-level rendering.
    y_down,
};

/// The vertical (Y) axis convention a *project* authors its logical
/// coordinates in. This is the single source of truth for "which way is +Y"
/// that every coordinate-producing and -consuming surface (entity positions,
/// the renderer flip, camera transforms, and picking) routes through, so the
/// camera and no-camera paths can never disagree.
///
/// See the Y-axis convention RFC (labelle-engine#638). `.down` is the
/// framework-native default (matches the screen, the mouse, and the renderer's
/// internal NDC space); `.up` is the opt-in math-/platformer-natural
/// convention that mirrors today's behavior.
pub const YAxis = enum {
    /// Logical Y grows **upward**, origin at the bottom (`y = 0` is the
    /// bottom edge). The renderer flips on the way out (`height - y`). This is
    /// the historical labelle behavior.
    up,

    /// Logical Y grows **downward**, origin at the top (`y = 0` is the top
    /// edge). This matches screen/render space, so the renderer flip is the
    /// identity.
    down,
};

/// Map a logical Y to screen Y under the given axis convention. This is the
/// **one** canonical vertical-flip transform — every layer (gfx renderer,
/// engine picking, camera world<->screen) routes its vertical flip through
/// here so the convention can never diverge between paths.
///
/// - `.up`   = bottom-origin (logical y grows upward): `screen_y = height - y`
///             (today's behavior — matches the gfx renderer's `screen_height - y`).
/// - `.down` = top-origin (logical y grows downward): `screen_y = y` (identity).
///
/// `screenToLogicalY` is the exact inverse for both conventions.
pub fn toScreenY(axis: YAxis, y: f32, height: f32) f32 {
    return switch (axis) {
        .up => height - y,
        .down => y,
    };
}

/// Map a screen Y back to logical Y under the given axis convention — the
/// inverse of `toScreenY`. Engine picking (`screenToLogical`) and camera
/// `screenToWorld` use this so screen->logical and logical->screen stay
/// consistent.
///
/// - `.up`   = `logical_y = height - screen_y`.
/// - `.down` = `logical_y = screen_y` (identity).
pub fn screenToLogicalY(axis: YAxis, screen_y: f32, height: f32) f32 {
    return switch (axis) {
        .up => height - screen_y,
        .down => screen_y,
    };
}

/// A position explicitly tagged as being in game (Y-up) coordinate space.
/// Use this at API boundaries to make the coordinate system unambiguous.
pub const GamePosition = struct {
    pos: Position,

    pub fn toScreen(self: GamePosition, screen_height: f32) ScreenPosition {
        return .{ .pos = .{
            .x = self.pos.x,
            .y = gameToScreen(self.pos.y, screen_height),
        } };
    }
};

/// A position explicitly tagged as being in screen (Y-down) coordinate space.
/// Use this at API boundaries to make the coordinate system unambiguous.
pub const ScreenPosition = struct {
    pos: Position,

    pub fn toGame(self: ScreenPosition, screen_height: f32) GamePosition {
        return .{ .pos = .{
            .x = self.pos.x,
            .y = screenToGame(self.pos.y, screen_height),
        } };
    }
};

/// Convert a Y value from game coordinates (Y-up, origin bottom-left) to
/// screen coordinates (Y-down, origin top-left).
///
/// screen_y = screen_height - game_y
pub fn gameToScreen(y: f32, screen_height: f32) f32 {
    return screen_height - y;
}

/// Convert a Y value from screen coordinates (Y-down, origin top-left) to
/// game coordinates (Y-up, origin bottom-left).
///
/// game_y = screen_height - screen_y
pub fn screenToGame(y: f32, screen_height: f32) f32 {
    return screen_height - y;
}
