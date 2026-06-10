//! Per-OS gamepad event source — **Wave 0 skeleton**.
//!
//! When a graphics/input backend (raylib, sdl, sokol, ...) declares NO
//! `pollGamepadEvents`, the engine's fallback drains hotplug events from
//! this comptime-selected OS source instead. Each platform owns exactly one
//! file under `src/gamepad_source/`; Wave-1 agents fill in their single file
//! and must NOT touch this selector or `build.zig`.
//!
//! ## Per-OS source interface (the contract each platform file implements)
//!
//! A platform file must expose a `pub const Source` namespace with:
//!
//! ```zig
//! pub const Source = struct {
//!     /// Optional one-time setup. Return error on hard init failure.
//!     pub fn init() void {}                  // optional (@hasDecl-guarded)
//!     /// Optional teardown.
//!     pub fn deinit() void {}                // optional (@hasDecl-guarded)
//!     /// Drain pending hotplug events into `out`; return the count written
//!     /// (never more than `out.len`). Stubs return 0.
//!     pub fn pollEvents(out: []GamepadEvent) usize { return 0; }
//!     /// Optional diagnostic enumeration (mirrors describeGamepads).
//!     pub fn describe(out: []GamepadDescription) usize { return 0; } // optional
//! };
//! ```
//!
//! `pollEvents` is REQUIRED; `init`/`deinit`/`describe` are optional and are
//! invoked only when present. This module re-exports the selected platform's
//! `Source` plus thin wrappers (`init`/`deinit`/`pollEvents`/`describe`) that
//! apply the `@hasDecl` fallbacks, so callers get a uniform surface.
//!
//! See labelle-toolkit/labelle-core#18.

const std = @import("std");
const builtin = @import("builtin");

const gamepad = @import("../gamepad.zig");
pub const GamepadEvent = gamepad.GamepadEvent;
pub const GamepadDescription = gamepad.GamepadDescription;

/// Comptime OS/abi dispatch. Each branch maps to exactly one owned file so
/// parallel Wave-1 work never collides. Android is detected via abi (there
/// is no `Target.Os.Tag.android`; `isAndroid` does not exist) per project
/// convention: `abi == .android or abi == .androideabi`.
pub const platform = blk: {
    const os = builtin.target.os.tag;
    const abi = builtin.target.abi;

    if (abi == .android or abi == .androideabi) {
        break :blk @import("android.zig"); // TODO(assembler#248)
    }

    break :blk switch (os) {
        .linux => @import("linux.zig"), // TODO(assembler#249)
        .ios, .tvos => @import("ios.zig"), // TODO(assembler#251)
        .wasi, .freestanding, .emscripten => if (builtin.target.cpu.arch.isWasm())
            @import("wasm.zig") // TODO(assembler#249)
        else
            @import("unsupported.zig"),
        else => @import("unsupported.zig"),
    };
};

/// The selected platform's `Source` namespace (see module doc for shape).
pub const Source = platform.Source;

comptime {
    // Freeze the contract: every platform file MUST expose `Source.pollEvents`.
    if (!@hasDecl(platform, "Source"))
        @compileError("gamepad_source platform file must define `pub const Source`");
    if (!@hasDecl(Source, "pollEvents"))
        @compileError("gamepad_source Source must define `pub fn pollEvents(out: []GamepadEvent) usize`");
}

/// One-time init for the selected source. No-op if the platform omits it.
pub fn init() void {
    if (@hasDecl(Source, "init")) Source.init();
}

/// Teardown for the selected source. No-op if the platform omits it.
pub fn deinit() void {
    if (@hasDecl(Source, "deinit")) Source.deinit();
}

/// Drain pending hotplug events from the selected OS source.
/// Returns the number of events written to `out` (0 on stub platforms).
pub fn pollEvents(out: []GamepadEvent) usize {
    return Source.pollEvents(out);
}

/// Diagnostic enumeration from the selected source. Returns 0 when the
/// platform provides no `describe`.
pub fn describe(out: []GamepadDescription) usize {
    if (@hasDecl(Source, "describe")) return Source.describe(out);
    return 0;
}

test "selected platform source drains 0 events by default (stub)" {
    var buf: [8]GamepadEvent = undefined;
    init();
    defer deinit();
    try std.testing.expectEqual(@as(usize, 0), pollEvents(&buf));
    var dbuf: [8]GamepadDescription = undefined;
    try std.testing.expectEqual(@as(usize, 0), describe(&dbuf));
}

test "selector maps the build target to the expected platform file" {
    // Assert the *selection logic* (not just that some Source exists): recompute
    // the expected platform module from the target the same way `platform` does,
    // and require the selector to have picked exactly that file. This fails if a
    // selector branch is reordered, dropped, or mis-wired — unlike a check that
    // only confirms `Source.pollEvents` exists, which every stub trivially passes.
    //
    // We deliberately do NOT force-import/compile every platform body on the host
    // (that would make `zig build test` fail once Wave-1 adds host-unavailable
    // SDK/JNI/browser code). Only the file selected for the current target is
    // referenced here; foreign-platform bodies are compile-checked when built for
    // their own target. The host-independent contract is frozen in the `comptime`
    // block above (lines 67-73).
    const os = builtin.target.os.tag;
    const abi = builtin.target.abi;

    const expected = comptime if (abi == .android or abi == .androideabi)
        @import("android.zig")
    else switch (os) {
        .linux => @import("linux.zig"),
        .ios, .tvos => @import("ios.zig"),
        .wasi, .freestanding, .emscripten => if (builtin.target.cpu.arch.isWasm())
            @import("wasm.zig")
        else
            @import("unsupported.zig"),
        else => @import("unsupported.zig"),
    };

    // Same module => the selector picked the right file for this target.
    try std.testing.expect(platform == expected);

    // The selected source satisfies the frozen contract and behaves as a stub.
    comptime std.debug.assert(@hasDecl(Source, "pollEvents"));
    var buf: [4]GamepadEvent = undefined;
    try std.testing.expectEqual(@as(usize, 0), Source.pollEvents(&buf));
}
