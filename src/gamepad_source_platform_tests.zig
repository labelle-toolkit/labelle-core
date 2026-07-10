//! Host-side collector for the per-OS gamepad_source platform files' own
//! `test` blocks (labelle-core#23, epic #609).
//!
//! ## Why this file exists
//!
//! `gamepad_source/root.zig` selects ONE platform file per target at comptime.
//! On the dev host it picks `unsupported.zig`, so `android.zig` / `ios.zig` /
//! `linux.zig` / `wasm.zig` are never semantically analysed by a host
//! `zig build test` — and Zig only collects `test` blocks from files it
//! analyses. The result: the platform files' *host-runnable, pure-logic* unit
//! tests (`classifySources`, `makeGuid`, `typeHintFromId`, `normalizeAxis`, the
//! WASM ring-buffer connect/disconnect diffing, the iOS enum/heuristic checks,
//! ...) passed only when run through a dedicated ad-hoc test root, never under
//! `zig build test`. Regressions in that pure logic could merge green.
//!
//! ## What this file does
//!
//! It force-imports each per-OS platform file so the compiler analyses it and
//! collects its `test` blocks into the host `test` step. Every platform file is
//! written to compile on ANY target — the native surface (Android JNI, Linux
//! udev/evdev, iOS GameController objc, the WASM JS-shim exports) is gated
//! behind a `comptime is_<platform>` branch (or a `FallbackSource`/`StubSource`
//! stand-in), so on the host the files reduce to their pure-Zig helpers plus a
//! no-op `Source`. That means every one of their `test` blocks is host-runnable
//! and runs here.
//!
//! ## What stays compile-checked only
//!
//! The *native* code paths (behind `is_android` / `is_linux` / `is_apple_mobile`
//! / `is_wasm`) are never taken on the host, so this collector does NOT exercise
//! them. They remain covered by the cross-compile `check-platforms` build step,
//! which builds `gamepad_source_platform_check.zig` for each foreign target and
//! `refAllDeclsRecursive`'s the real per-target `Source`, front-end-checking the
//! native bodies without requiring an NDK/SDK/browser to link. Host run here +
//! foreign compile-check there = full coverage of both halves.
//!
//! This module has NO non-test surface and is intentionally NOT re-exported from
//! `src/root.zig`: it is wired straight into a dedicated host `test` artifact in
//! `build.zig`, so consumers building `labelle-core` for a foreign target never
//! pull these host-only test blocks in.

comptime {
    _ = @import("gamepad_source/android.zig");
    _ = @import("gamepad_source/linux.zig");
    _ = @import("gamepad_source/wasm.zig");
    _ = @import("gamepad_source/ios.zig");
    _ = @import("gamepad_source/unsupported.zig");
}
