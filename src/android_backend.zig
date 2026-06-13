//! Backend-agnostic Android JNI seam (labelle-core#310, Stage 1).
//!
//! ## Why this exists
//!
//! Core's Android gamepad source (`gamepad_source/android.zig`) needs three
//! native entry points to reach the running `ANativeActivity` and drive the
//! InputManager JNI glue:
//!
//!   1. get the `ANativeActivity*` of the running app,
//!   2. register the InputDeviceListener + enumerate devices,
//!   3. unregister the listener on teardown.
//!
//! Historically core hard-coded these as `extern` symbols (`sapp_*` /
//! `labelle_android_gamepad_*`) provided by **sokol** at link time. That forced
//! *every* backend (raylib, bgfx, ...) to export fake `sapp_*` stubs just so
//! core would link on Android — a sokol-shaped dependency leaking into core.
//!
//! This module breaks that coupling. Instead of linking against fixed sokol
//! symbols, core asks for an `AndroidBackendContext` — a small vtable of C
//! function pointers — that the active backend adapter **registers at startup**.
//! Core then routes its JNI calls through whatever context was registered.
//!
//!   * sokol backend  → registers a context wired to `sapp_android_get_native_activity`
//!                       and its `labelle_android_gamepad_*` C glue (Stage: sokol adapter).
//!   * other backends → register a context if/when they support Android gamepads,
//!                       or register nothing → core's Android gamepad source is a
//!                       graceful no-op (no link error, no fake stubs needed).
//!
//! ## Contract / lifecycle
//!
//! The backend adapter (or the engine on its behalf) MUST call
//! `registerAndroidBackend(ctx)` **once, at startup, before the gamepad source
//! is initialized** (i.e. before `gamepad_source.init()` runs). The function
//! pointers in `ctx` must remain valid for the lifetime of the process.
//!
//! If no context is registered, `get()` returns `null` and the Android gamepad
//! source degrades to an inert no-op (it polls zero events). This is the
//! intended behavior for backends that don't ship Android gamepad JNI glue.
//!
//! ## Threading
//!
//! Registration is a single startup-time write; `get()` is a read. Because
//! registration happens once before any reader runs, a plain module-level
//! optional is sufficient and matches core's Io-free constraints (no
//! `std.Io.Mutex` handle is available this deep in init). Do not call
//! `registerAndroidBackend` concurrently with gamepad polling.
//!
//! All function pointers use the C calling convention (`callconv(.c)`) so a
//! backend can wire them straight to C glue / sokol exports without a shim.

/// Vtable the active backend hands to core so core can reach the Android JNI
/// layer without linking any backend-specific symbol directly.
pub const AndroidBackendContext = struct {
    /// Return the running `ANativeActivity*` (as an opaque pointer), or `null`
    /// if no Activity is available yet. Core treats `null` as "nothing to bind".
    get_native_activity: *const fn () callconv(.c) ?*anyopaque,

    /// Register the InputDeviceListener and enumerate existing input devices,
    /// pushing `.connected` events through core's exported
    /// `labelle_android_on_device_added` / `_removed` callbacks. `activity` is
    /// the value returned by `get_native_activity` (guaranteed non-null here).
    gamepad_init: *const fn (activity: ?*anyopaque) callconv(.c) void,

    /// Unregister the InputDeviceListener installed by `gamepad_init`.
    gamepad_shutdown: *const fn () callconv(.c) void,
};

/// The single backend context, set once at startup. `null` until a backend
/// registers one (and forever, for backends without Android gamepad support).
var registered: ?AndroidBackendContext = null;

/// Register the active backend's Android JNI seam. Call once at startup, before
/// the gamepad source initializes. The pointers must outlive the process. A
/// later call overwrites the previous registration (last writer wins).
pub fn registerAndroidBackend(ctx: AndroidBackendContext) void {
    registered = ctx;
}

/// The registered Android backend context, or `null` if none was registered
/// (in which case core's Android gamepad source is a graceful no-op).
pub fn get() ?AndroidBackendContext {
    return registered;
}

/// Drop any registered context. Primarily for tests; production code registers
/// once and never clears.
pub fn reset() void {
    registered = null;
}

const std = @import("std");

test "get() is null until a backend registers" {
    reset();
    defer reset();
    try std.testing.expect(get() == null);
}

test "registerAndroidBackend installs a retrievable context" {
    reset();
    defer reset();

    const Glue = struct {
        var inited: bool = false;
        var shut: bool = false;
        fn activity() callconv(.c) ?*anyopaque {
            return null;
        }
        fn doInit(_: ?*anyopaque) callconv(.c) void {
            inited = true;
        }
        fn doShutdown() callconv(.c) void {
            shut = true;
        }
    };

    registerAndroidBackend(.{
        .get_native_activity = &Glue.activity,
        .gamepad_init = &Glue.doInit,
        .gamepad_shutdown = &Glue.doShutdown,
    });

    const ctx = get() orelse return error.NoContext;
    try std.testing.expect(ctx.get_native_activity() == null);
    ctx.gamepad_init(null);
    ctx.gamepad_shutdown();
    try std.testing.expect(Glue.inited);
    try std.testing.expect(Glue.shut);
}
