//! iOS / tvOS gamepad event source (GameController.framework).
//!
//! Observes GCControllerDidConnect/DidDisconnect and classifies tvOS Siri
//! Remote as `source_class == .dpad_remote`. Wave-0 stub: returns no events.
//!
//! TODO(assembler#251): implement GameController.framework bridge. Fill in
//! `Source` below; do NOT touch ../gamepad_source/root.zig or build.zig.

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
