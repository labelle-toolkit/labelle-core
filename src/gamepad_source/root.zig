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
//! ## Optional STATE surface (core#28)
//!
//! Beyond hotplug detection, a source MAY also carry button/axis **state** so
//! the engine can read controllers through the platform source instead of the
//! render backend's bundled library. The optional state contract is:
//!
//! ```zig
//!     pub fn update() void {}                          // pump once per frame
//!     pub fn isAvailable(slot: u32) bool { ... }
//!     pub fn isButtonDown(slot: u32, button: u32) bool { ... }
//!     pub fn isButtonPressed(slot: u32, button: u32) bool { ... }
//!     pub fn axisValue(slot: u32, axis: u32) f32 { ... }
//! ```
//!
//! All five are OPTIONAL and resolved via `@hasDecl` at the wrappers below, so
//! detection-only sources (android/ios/linux/wasm/unsupported) that define
//! only `pollEvents` still satisfy the contract. Buttons/axes use the
//! canonical raylib-compatible numbering. `hasState()` lets the engine decide
//! at comptime whether to prefer the source over the backend `Impl`.
//!
//! See labelle-toolkit/labelle-core#18 and #28.

const std = @import("std");
const builtin = @import("builtin");

const gamepad = @import("../gamepad.zig");
pub const GamepadEvent = gamepad.GamepadEvent;
pub const GamepadDescription = gamepad.GamepadDescription;
// Re-exported so per-OS source files (e.g. `android.zig`, which classifies a
// device's `InputDevice.getSources()` bitmask into a `.gamepad`/`.dpad_remote`
// class) can name this type through `@import("root.zig")` without reaching back
// into `../gamepad.zig`. Without it `android.zig` fails to compile for the
// Android target (labelle-core#23).
pub const SourceClass = gamepad.SourceClass;

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
        // Linux keeps its hand-rolled libudev source for now. Consolidating
        // Linux onto the SDL-backed `desktop.zig` (which would also give Linux
        // button/axis *state*) is a deliberate follow-up — see core#28 — so
        // this PR does not disturb the working evdev/udev detection path.
        .linux => @import("linux.zig"), // TODO(assembler#249)
        .ios, .tvos => @import("ios.zig"), // TODO(assembler#251)
        // macOS / Windows: windowless SDL2 desktop source (detection + state).
        .macos, .windows => @import("desktop.zig"), // core#28
        .wasi, .freestanding, .emscripten => if (builtin.target.cpu.arch.isWasm())
            @import("wasm.zig") // TODO(assembler#249)
        else
            @import("unsupported.zig"),
        else => @import("unsupported.zig"),
    };
};

/// The selected platform's `Source` namespace (see module doc for shape).
pub const Source = platform.Source;

/// The windowless-SDL desktop module, re-exported ONLY on the desktop targets
/// that select it (macOS/Windows). Lets host tests exercise its pure
/// SDL→canonical mapping/normalize helpers directly (they execute on the
/// host, unlike the platform files' inline `test` blocks, which the
/// `src/root.zig` test artifact does not collect). `null` elsewhere.
pub const desktop = if (builtin.target.os.tag == .macos or builtin.target.os.tag == .windows)
    @import("desktop.zig")
else
    null;

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

// ── Optional STATE surface (core#28) ────────────────────────────────────
//
// Forwarders for the optional button/axis state contract. Each is guarded by
// `@hasDecl` so detection-only sources (which define only `pollEvents`) keep
// compiling; on those the wrapper is a safe no-op (false/0). Callers (the
// engine, in a follow-up PR) read these to source gamepad state from the
// platform rather than the render backend.

/// True at comptime when the selected source implements the full state
/// surface. Lets callers prefer the source over the backend `Impl` only when
/// it can actually answer state queries.
pub fn hasState() bool {
    return @hasDecl(Source, "isAvailable") and
        @hasDecl(Source, "isButtonDown") and
        @hasDecl(Source, "isButtonPressed") and
        @hasDecl(Source, "axisValue");
}

/// Pump/refresh the source once per frame. No-op when the source omits it
/// (detection-only sources need no per-frame pump).
pub fn update() void {
    if (@hasDecl(Source, "update")) Source.update();
}

/// True if a controller is connected in `slot`. False when unsupported.
pub fn isAvailable(slot: u32) bool {
    if (@hasDecl(Source, "isAvailable")) return Source.isAvailable(slot);
    return false;
}

/// True while canonical `button` is held on `slot`. False when unsupported.
pub fn isButtonDown(slot: u32, button: u32) bool {
    if (@hasDecl(Source, "isButtonDown")) return Source.isButtonDown(slot, button);
    return false;
}

/// True on the frame canonical `button` transitions up→down on `slot`.
/// False when unsupported.
pub fn isButtonPressed(slot: u32, button: u32) bool {
    if (@hasDecl(Source, "isButtonPressed")) return Source.isButtonPressed(slot, button);
    return false;
}

/// Normalized value of canonical `axis` on `slot` (sticks [-1,1], triggers
/// [0,1]). 0 when unsupported.
pub fn axisValue(slot: u32, axis: u32) f32 {
    if (@hasDecl(Source, "axisValue")) return Source.axisValue(slot, axis);
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
        .macos, .windows => @import("desktop.zig"),
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
    _ = Source.pollEvents(&buf);
}

test "optional state surface forwards safely on every host target" {
    // The wrappers must be callable regardless of whether the selected source
    // implements the state contract. On a detection-only host source they
    // return the safe defaults; on the SDL desktop source (macOS/Windows host)
    // they read as empty because no `update()`/controllers exist headlessly.
    update();
    try std.testing.expect(!isAvailable(0));
    try std.testing.expect(!isButtonDown(0, 1));
    try std.testing.expect(!isButtonPressed(0, 1));
    try std.testing.expectEqual(@as(f32, 0), axisValue(0, 0));

    // `hasState()` is true exactly when the source defines all four queries.
    const expect_state = @hasDecl(Source, "isAvailable") and
        @hasDecl(Source, "isButtonDown") and
        @hasDecl(Source, "isButtonPressed") and
        @hasDecl(Source, "axisValue");
    try std.testing.expectEqual(expect_state, hasState());
}
