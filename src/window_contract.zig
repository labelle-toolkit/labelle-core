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
        // Optional-but-paired: surface loss is a single capability with two
        // halves — a backend that declares one without the other would leave
        // the surface either un-forgotten or un-restored. Surface it as a
        // contract violation, mirroring the `isCompressed+uploadCompressed`
        // pairing check in `backend_contract`.
        if (@hasDecl(Impl, "surfaceLost") != @hasDecl(Impl, "surfaceRestored")) {
            missing = missing ++ [_][]const u8{"surfaceLost+surfaceRestored (must define both or neither)"};
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

/// Optional, synchronous window operations for a game-drawn mouse pointer.
/// The generated host binds these callbacks after creating its window; they
/// must be called on that window's thread. Missing operations return false.
/// Callbacks borrow no state and remain valid for the lifetime of the program.
pub const CursorControls = struct {
    set_visible: *const fn (bool) bool = unsupportedVisibility,
    is_over_window: *const fn () bool = unsupportedHover,

    fn unsupportedVisibility(_: bool) bool {
        return false;
    }
    fn unsupportedHover() bool {
        return false;
    }

    /// Adapt optional window declarations without requiring a backend upgrade.
    /// false from set_visible means no pointer was hidden: callers must not
    /// draw a replacement. The query excludes unfocused/outside/touch-only
    /// surfaces. Hiding never locks, warps or remaps pointer coordinates.
    pub fn fromWindow(comptime Impl: type) CursorControls {
        return .{
            .set_visible = if (@hasDecl(Impl, "setCursorVisible")) Impl.setCursorVisible else unsupportedVisibility,
            .is_over_window = if (@hasDecl(Impl, "isCursorOverWindow")) Impl.isCursorOverWindow else unsupportedHover,
        };
    }
};

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

        /// Show/restore the system pointer, or hide it for a game overlay.
        /// Returns false if unavailable; never changes coordinate mapping.
        pub inline fn setCursorVisible(visible: bool) bool {
            return CursorControls.fromWindow(Impl).set_visible(visible);
        }

        /// A mouse/pen is over the focused game surface. False if unsupported.
        pub inline fn isCursorOverWindow() bool {
            return CursorControls.fromWindow(Impl).is_over_window();
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

        // ── GPU surface loss (optional — mobile lifecycle, epic #386 Phase 4) ──
        //
        // On Android, TERM_WINDOW destroys every GPU texture while game state and
        // the CPU allocator survive; INIT_WINDOW recreates the surface. Backends
        // whose platform layer observes these events declare BOTH hooks (they are
        // a paired unit); desktop backends omit both and the wrappers no-op.

        /// `true` if this backend can lose and restore its GPU surface at runtime
        /// (declares BOTH `surfaceLost` and `surfaceRestored`). Pure `@hasDecl`
        /// reflection, mirroring `ownsLoop`/`canScreenshot` — the splice checks it
        /// against the manifest's `surface_loss` capability.
        pub inline fn supportsSurfaceLoss() bool {
            return @hasDecl(Impl, "surfaceLost") and @hasDecl(Impl, "surfaceRestored");
        }

        /// The GPU surface died (e.g. Android TERM_WINDOW). Every GPU handle is
        /// already DEAD: the backend must FORGET its surface-dependent state and
        /// must NEVER free/destroy handles on the dead context (that is UB). No
        /// GPU work may run until `surfaceRestored`. Safe no-op when undeclared.
        pub inline fn surfaceLost() void {
            if (@hasDecl(Impl, "surfaceLost")) Impl.surfaceLost();
        }

        /// A fresh GPU surface exists again (e.g. Android INIT_WINDOW). From this
        /// point re-uploads (decode → upload through the render loader surface)
        /// are safe. Safe no-op when undeclared.
        pub inline fn surfaceRestored() void {
            if (@hasDecl(Impl, "surfaceRestored")) Impl.surfaceRestored();
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

test "cursor controls safely default for old or partial backends" {
    const testing = @import("std").testing;
    try testing.expect(!Window(StubWindow).setCursorVisible(false));
    try testing.expect(!Window(StubWindow).isCursorOverWindow());
    const Partial = struct {
        pub fn isCursorOverWindow() bool {
            return true;
        }
    };
    const partial = CursorControls.fromWindow(Partial);
    try testing.expect(partial.is_over_window());
    try testing.expect(!partial.set_visible(false));
}

test "cursor controls forward the requested value and backend result" {
    const testing = @import("std").testing;
    const Fake = struct {
        var visible: bool = true;
        var available: bool = true;
        pub fn setCursorVisible(value: bool) bool {
            if (!available) return false;
            visible = value;
            return true;
        }
        pub fn isCursorOverWindow() bool {
            return available;
        }
    };
    Fake.visible = true;
    Fake.available = true;
    const controls = CursorControls.fromWindow(Fake);
    try testing.expect(controls.set_visible(false));
    try testing.expect(!Fake.visible);
    try testing.expect(controls.set_visible(true));
    try testing.expect(Fake.visible);
    Fake.available = false;
    try testing.expect(!controls.set_visible(false));
    try testing.expect(!controls.is_over_window());
    try testing.expect(Fake.visible);
}
