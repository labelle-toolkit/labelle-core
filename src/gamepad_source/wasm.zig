//! WebAssembly gamepad event source (browser Gamepad API).
//!
//! Bridges navigator.getGamepads() + gamepadconnected/disconnected events
//! from JS. Wave-0 stub: returns no events.
//!
//! TODO(assembler#249): implement Gamepad API bridge. Fill in `Source` below;
//! do NOT touch ../gamepad_source/root.zig or build.zig.

const source = @import("root.zig");
const GamepadEvent = source.GamepadEvent;
const GamepadDescription = source.GamepadDescription;

pub const Source = struct {
    pub fn pollEvents(out: []GamepadEvent) usize {
        _ = out;
        return 0;
    }

    pub fn describe(out: []GamepadDescription) usize {
        _ = out;
        return 0;
    }
};
