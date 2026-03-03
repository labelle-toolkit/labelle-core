/// Position component - stores LOCAL coordinates (offset from parent if parented)
///
/// When entity has a Parent component, Position is relative to parent.
/// World position = parent world position + rotated(local position)
///
/// Example in .zon:
/// ```
/// .Position = .{ .x = 100, .y = 200 },
/// .Position = .{ .x = 100, .y = 200, .rotation = 0.785 },  // 45 degrees
/// ```
pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
    /// Rotation in radians (used by physics and rendering)
    rotation: f32 = 0,
};
