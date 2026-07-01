const gamepad = @import("gamepad.zig");

/// Cross-backend gamepad event/diagnostic value types. Re-exported here so
/// callers can reach them via `input.GamepadEvent` etc.
pub const GamepadEvent = gamepad.GamepadEvent;
pub const GamepadDescription = gamepad.GamepadDescription;
pub const GamepadSourceClass = gamepad.SourceClass;
pub const GamepadTypeHint = gamepad.TypeHint;
pub const GamepadUnavailableReason = gamepad.UnavailableReason;

// ── Input contract (formalized — mirrors backend_contract.zig) ──────────────
//
// The duck-typed `@hasDecl` checks `InputInterface` made inline, lifted into the
// same shape the render `Backend` contract uses: a required-decls array + a
// `missingInputDecls` query + an `assertInput` gate. Input is intentionally MORE
// permissive than render — only the keyboard core is required; mouse/touch/
// gamepad/gesture stay OPTIONAL (a headless or remote-only backend declares
// none, and `InputInterface`'s `@hasDecl` fallbacks return 0/false).

/// Contract-version integer for the input surface (labelle-assembler#453, RFC
/// §"Versioning"). MONOTONIC, NOT semver: bump by 1 only on a BREAKING change to
/// the required input decl set (`required_input_decls`) or the signatures of the
/// required/capability-gated methods. Adding a new `@hasDecl`-gated optional
/// capability (mouse/touch/gamepad/gesture) is non-breaking and does NOT bump
/// it. A backend declares the version it targets; the assembler-generated
/// adapter asserts `N == M` — that emit is a deferred follow-up, this constant
/// is its ABI home.
pub const INPUT_CONTRACT_VERSION: u32 = 1;

/// The minimum every input backend must declare. Kept deliberately small — the
/// rest of the surface degrades gracefully via the `@hasDecl` fallbacks below.
pub const required_input_decls = [_][]const u8{ "isKeyDown", "isKeyPressed" };

/// Names of required decls `Impl` is missing, or an empty slice if it satisfies
/// the contract. `assertInput` wraps this with `@compileError`; tests call it
/// directly to assert acceptance/rejection without a compile failure. Mirrors
/// `backend_contract.missingBackendDecls`.
pub fn missingInputDecls(comptime Impl: type) []const []const u8 {
    comptime {
        var missing: []const []const u8 = &.{};
        // Plain `for`: already a `comptime {}` scope, so `name` is comptime each
        // iteration (`inline` would be a redundant Zig 0.16 error — see
        // backend_contract.missingBackendDecls).
        for (required_input_decls) |name| {
            if (!@hasDecl(Impl, name)) missing = missing ++ [_][]const u8{name};
        }
        return missing;
    }
}

/// Fail loudly at comptime if `Impl` doesn't satisfy the input contract, naming
/// every missing decl. The formal replacement for the duck-typed `@hasDecl`
/// checks `InputInterface` made inline. Mirrors `backend_contract.assertBackend`.
pub fn assertInput(comptime Impl: type) void {
    comptime {
        const missing = missingInputDecls(Impl);
        if (missing.len != 0) {
            var msg: []const u8 = "Input impl does not satisfy the input contract — missing decl(s):";
            for (missing) |name| msg = msg ++ "\n  - " ++ name;
            @compileError(msg);
        }
    }
}

/// Comptime-validated input interface.
/// The assembler provides the concrete Impl (raylib, sokol, etc.).
/// Both engine and plugins use this for zero-cost dispatch.
///
/// **Coordinate convention:** Mouse and touch positions returned by backend
/// implementations are in screen coordinates (Y-down, origin at top-left).
/// Callers should use `coordinates.screenToGame` to convert these to game
/// coordinates (Y-up) before using them in game logic.
pub fn InputInterface(comptime Impl: type) type {
    comptime assertInput(Impl);

    return struct {
        pub const Implementation = Impl;

        // ── Keyboard ──────────────────────────────────────────────

        pub inline fn isKeyDown(key: u32) bool {
            return Impl.isKeyDown(key);
        }

        pub inline fn isKeyPressed(key: u32) bool {
            return Impl.isKeyPressed(key);
        }

        pub inline fn isKeyReleased(key: u32) bool {
            if (@hasDecl(Impl, "isKeyReleased")) return Impl.isKeyReleased(key);
            return false;
        }

        // ── Mouse ─────────────────────────────────────────────────

        pub inline fn getMouseX() f32 {
            if (@hasDecl(Impl, "getMouseX")) return Impl.getMouseX();
            return 0;
        }

        pub inline fn getMouseY() f32 {
            if (@hasDecl(Impl, "getMouseY")) return Impl.getMouseY();
            return 0;
        }

        pub inline fn isMouseButtonDown(button: u32) bool {
            if (@hasDecl(Impl, "isMouseButtonDown")) return Impl.isMouseButtonDown(button);
            return false;
        }

        pub inline fn isMouseButtonPressed(button: u32) bool {
            if (@hasDecl(Impl, "isMouseButtonPressed")) return Impl.isMouseButtonPressed(button);
            return false;
        }

        pub inline fn isMouseButtonReleased(button: u32) bool {
            if (@hasDecl(Impl, "isMouseButtonReleased")) return Impl.isMouseButtonReleased(button);
            return false;
        }

        pub inline fn getMouseWheelMove() f32 {
            if (@hasDecl(Impl, "getMouseWheelMove")) return Impl.getMouseWheelMove();
            return 0;
        }

        // ── Touch ─────────────────────────────────────────────────

        pub inline fn getTouchCount() u32 {
            if (@hasDecl(Impl, "getTouchCount")) return Impl.getTouchCount();
            return 0;
        }

        pub inline fn getTouchX(index: u32) f32 {
            if (@hasDecl(Impl, "getTouchX")) return Impl.getTouchX(index);
            return 0;
        }

        pub inline fn getTouchY(index: u32) f32 {
            if (@hasDecl(Impl, "getTouchY")) return Impl.getTouchY(index);
            return 0;
        }

        pub inline fn getTouchId(index: u32) u64 {
            if (@hasDecl(Impl, "getTouchId")) return Impl.getTouchId(index);
            return 0;
        }

        // ── Gamepad ───────────────────────────────────────────────

        pub inline fn isGamepadAvailable(gamepad_id: u32) bool {
            if (@hasDecl(Impl, "isGamepadAvailable")) return Impl.isGamepadAvailable(gamepad_id);
            return false;
        }

        pub inline fn isGamepadButtonDown(gamepad_id: u32, button: u32) bool {
            if (@hasDecl(Impl, "isGamepadButtonDown")) return Impl.isGamepadButtonDown(gamepad_id, button);
            return false;
        }

        pub inline fn isGamepadButtonPressed(gamepad_id: u32, button: u32) bool {
            if (@hasDecl(Impl, "isGamepadButtonPressed")) return Impl.isGamepadButtonPressed(gamepad_id, button);
            return false;
        }

        pub inline fn getGamepadAxisValue(gamepad_id: u32, axis: u32) f32 {
            if (@hasDecl(Impl, "getGamepadAxisValue")) return Impl.getGamepadAxisValue(gamepad_id, axis);
            return 0;
        }

        // ── Gamepad hotplug events (Phase 0 contract, core#18) ───────
        //
        // Backends declare these to source connect/disconnect events and a
        // diagnostic device list. Both are COPY-only (see gamepad.zig). When
        // a backend declares neither, the fallbacks return 0 — preserving
        // today's "nothing happens" behavior. The engine's own fallback may
        // instead route to `gamepad_source` (the per-OS skeleton) when a
        // backend has no `pollGamepadEvents`.

        /// Drain pending hotplug (connect/disconnect) events into `out`.
        /// Returns the number of events written (never more than `out.len`).
        /// A backend Impl declares: `pub fn pollGamepadEvents(out: []GamepadEvent) usize`.
        pub inline fn pollGamepadEvents(out: []GamepadEvent) usize {
            if (@hasDecl(Impl, "pollGamepadEvents")) return Impl.pollGamepadEvents(out);
            return 0;
        }

        /// Enumerate currently-visible devices for diagnostics/logging,
        /// including an `unavailable_reason` for devices that are detected
        /// but cannot be opened (e.g. Linux permission denied).
        /// Returns the number of descriptions written (never more than `out.len`).
        /// A backend Impl declares: `pub fn describeGamepads(out: []GamepadDescription) usize`.
        pub inline fn describeGamepads(out: []GamepadDescription) usize {
            if (@hasDecl(Impl, "describeGamepads")) return Impl.describeGamepads(out);
            return 0;
        }

        // ── Gestures ─────────────────────────────────────────────

        /// Poll/update gesture recognition state. Mobile backends with
        /// touch-gesture support implement this; others safely no-op.
        pub inline fn updateGestures(dt: f32) void {
            if (@hasDecl(Impl, "updateGestures")) Impl.updateGestures(dt);
        }
    };
}

/// Stub input for testing — all methods return false/zero.
pub const StubInput = struct {
    pub fn isKeyDown(_: u32) bool { return false; }
    pub fn isKeyPressed(_: u32) bool { return false; }
    pub fn isKeyReleased(_: u32) bool { return false; }
    pub fn getMouseX() f32 { return 0; }
    pub fn getMouseY() f32 { return 0; }
    pub fn isMouseButtonDown(_: u32) bool { return false; }
    pub fn isMouseButtonPressed(_: u32) bool { return false; }
    pub fn isMouseButtonReleased(_: u32) bool { return false; }
    pub fn getMouseWheelMove() f32 { return 0; }
    pub fn getTouchCount() u32 { return 0; }
    pub fn getTouchX(_: u32) f32 { return 0; }
    pub fn getTouchY(_: u32) f32 { return 0; }
    pub fn getTouchId(_: u32) u64 { return 0; }
    pub fn isGamepadAvailable(_: u32) bool { return false; }
    pub fn isGamepadButtonDown(_: u32, _: u32) bool { return false; }
    pub fn isGamepadButtonPressed(_: u32, _: u32) bool { return false; }
    pub fn getGamepadAxisValue(_: u32, _: u32) f32 { return 0; }
};
