//! Default/fallback gamepad event source for platforms without a native
//! OS source (e.g. desktop where the windowing backend already supplies
//! gamepad polling, or any unhandled target). Always returns no events;
//! `describe` reports `.unsupported`.
//!
//! This file is the selector's default branch and is intentionally complete
//! (not a TODO stub). Do NOT add platform logic here — add a new platform
//! file and a selector branch instead.

const source = @import("root.zig");
const GamepadEvent = source.GamepadEvent;
const GamepadDescription = source.GamepadDescription;

pub const Source = struct {
    pub fn pollEvents(out: []GamepadEvent) usize {
        _ = out;
        return 0;
    }

    pub fn describe(out: []GamepadDescription) usize {
        // Report up to out.len slots as unsupported for diagnostics.
        for (out, 0..) |*d, i| {
            d.* = .{ .slot = @intCast(i), .unavailable_reason = .unsupported };
        }
        return 0; // no usable devices
    }
};
