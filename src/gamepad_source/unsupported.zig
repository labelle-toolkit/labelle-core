//! Default/fallback gamepad event source for platforms without a native
//! OS source (e.g. desktop where the windowing backend already supplies
//! gamepad polling, or any unhandled target). Always returns no events and
//! reports no devices (`describe` writes nothing and returns 0).
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
        // No usable devices on the fallback target, so no descriptions are
        // written. Return 0 to match the contract (return value == number of
        // descriptions written) and the other platform stubs.
        _ = out;
        return 0;
    }
};
