//! The window contract — the inversion-of-control seam of the pluggable-backends
//! RFC (#378, epic #386 Phase 3). The window owns the run loop and the platform
//! surface; the engine/assembler drive it through this uniform interface.
//!
//! ## Why this mirrors `input`, not `backend_contract` (render)
//! Unlike render (one uniform `Backend` surface), window surfaces diverge by
//! **run-loop model**, not just naming:
//!   - a *loop* backend (raylib, bgfx) owns a `while (!shouldQuit())` loop;
//!   - a *callback* backend (sokol, mobile, wasm) is pumped by the OS/browser and
//!     has **no** `shouldQuit` to gate.
//! Their per-frame shapes differ too — `beginFrame` returns a backend-specific
//! pass token on sokol but `void` on raylib/bgfx. So a large *strict* surface is
//! impossible. Instead, like the input contract, the required core is tiny and
//! reliably universal; everything loop-model-specific is **capability-gated**
//! (`@hasDecl`) and discovered per backend (the splice manifest's `loop_style`
//! already carries the loop-vs-callback distinction).
//!
//! The canonical **names** here are the unification target for the
//! `beginDrawing→beginFrame`, `getScreenWidth→width`, `windowShouldClose→
//! shouldQuit` rename across the backends (so the run-loop templates can be
//! shared instead of per-dialect). Conforming the backends is a follow-up slice;
//! this file is the canonical surface they rename *to*.

/// Contract-version integer for the window surface (labelle-assembler#453, RFC
/// §"Versioning"). MONOTONIC, NOT semver: bump by 1 only on a BREAKING change to
/// the required window decl set (`required_window_decls`) or the signatures of
/// the required/capability-gated methods. Adding a new capability-gated
/// (`@hasDecl`) optional is non-breaking and does NOT bump it. A backend
/// declares the version it targets; the assembler-generated adapter asserts
/// `N == M` — that emit is a deferred follow-up, this constant is its ABI home.
pub const WINDOW_CONTRACT_VERSION: u32 = 1;

/// The minimum every window backend must declare — the engine-facing surface
/// that is identical across loop and callback models. Kept small on purpose:
/// the loop-specific (`shouldQuit`) and per-frame (`beginFrame`/`endFrame`)
/// methods are capability-gated below, not required.
pub const required_window_decls = [_][]const u8{
    "width", // i32 — current framebuffer width
    "height", // i32 — current framebuffer height
    "frameDuration", // f64 — seconds elapsed for the last frame (dt source)
    "requestQuit", // void — ask the window to end the run loop
};

/// Names of required decls `Impl` is missing, or an empty slice if it satisfies
/// the contract. `assertWindow` wraps this with `@compileError`; tests call it
/// directly. Mirrors `backend_contract.missingBackendDecls` /
/// `input.missingInputDecls`.
pub fn missingWindowDecls(comptime Impl: type) []const []const u8 {
    comptime {
        var missing: []const []const u8 = &.{};
        for (required_window_decls) |name| {
            if (!@hasDecl(Impl, name)) missing = missing ++ [_][]const u8{name};
        }
        return missing;
    }
}

/// Fail loudly at comptime if `Impl` doesn't satisfy the window contract, naming
/// every missing decl. Mirrors `backend_contract.assertBackend` /
/// `input.assertInput`.
pub fn assertWindow(comptime Impl: type) void {
    comptime {
        const missing = missingWindowDecls(Impl);
        if (missing.len != 0) {
            var msg: []const u8 = "Window impl does not satisfy the window contract — missing decl(s):";
            for (missing) |name| msg = msg ++ "\n  - " ++ name;
            @compileError(msg);
        }
    }
}

/// Comptime-validated window interface. The required core dispatches directly;
/// the loop-model-specific and display-toggle methods are capability-gated
/// (`@hasDecl`) with safe fallbacks, so a callback backend without `shouldQuit`
/// or a backend without `setVsync` still instantiates and degrades gracefully.
pub fn Window(comptime Impl: type) type {
    comptime assertWindow(Impl);

    return struct {
        pub const Implementation = Impl;

        // ── Required core (uniform across loop + callback models) ──────────

        pub inline fn width() i32 {
            return Impl.width();
        }
        pub inline fn height() i32 {
            return Impl.height();
        }
        /// Seconds elapsed for the last frame — the engine's `dt` source.
        pub inline fn frameDuration() f64 {
            return Impl.frameDuration();
        }
        pub inline fn requestQuit() void {
            Impl.requestQuit();
        }

        // ── Loop-model: present on *loop* backends, absent on *callback* ───
        //
        // A loop backend's entry point gates on `shouldQuit()`; a callback
        // backend has no loop to gate (the OS/browser pumps frames), so it
        // omits this and the fallback reports "keep running" — the callback
        // backend ends the app via `requestQuit` + its own pump instead.

        pub inline fn shouldQuit() bool {
            if (@hasDecl(Impl, "shouldQuit")) return Impl.shouldQuit();
            return false;
        }

        /// `true` if this backend declares `shouldQuit` — i.e. it is a loop-model
        /// backend whose entry point owns a `while (!shouldQuit())` loop. Lets
        /// the splice pick the loop vs callback entry shape from the type, in
        /// step with the manifest's `loop_style`.
        pub inline fn ownsLoop() bool {
            return @hasDecl(Impl, "shouldQuit");
        }

        // ── Display toggles (optional — engine-owned flag, backend applies) ─

        pub inline fn isFullscreen() bool {
            if (@hasDecl(Impl, "isFullscreen")) return Impl.isFullscreen();
            return false;
        }
        pub inline fn setFullscreen(on: bool) void {
            if (@hasDecl(Impl, "setFullscreen")) Impl.setFullscreen(on);
        }
        pub inline fn setVsync(on: bool) void {
            if (@hasDecl(Impl, "setVsync")) Impl.setVsync(on);
        }

        // ── Screenshot (optional) ──────────────────────────────────────────

        /// `true` if this backend can capture a screenshot to a file path.
        pub inline fn canScreenshot() bool {
            return @hasDecl(Impl, "takeScreenshot");
        }
        pub inline fn takeScreenshot(path: [:0]const u8) void {
            if (@hasDecl(Impl, "takeScreenshot")) Impl.takeScreenshot(path);
        }
    };
}

/// Reference window impl for tests — satisfies the required core, declares none
/// of the optionals (a minimal callback-style backend). Mirrors `StubInput` /
/// `MockBackend`.
pub const StubWindow = struct {
    pub fn width() i32 {
        return 0;
    }
    pub fn height() i32 {
        return 0;
    }
    pub fn frameDuration() f64 {
        return 0;
    }
    pub fn requestQuit() void {}
};
