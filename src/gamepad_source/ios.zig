//! iOS / tvOS gamepad event source — GameController.framework bridge.
//!
//! Owns the single connection point to Apple's GameController.framework for
//! both **hotplug detection** (this file's `Source.pollEvents` / `describe`)
//! and **button/axis state** (queried by the sokol input backend through the
//! exported `labelle_gc_*` C symbols at the bottom of this file).
//!
//! ## Why this file owns the GC state
//!
//! Apple's `GCController` objects are the authoritative state for both the
//! hotplug list *and* the live button/axis values. There is exactly one set
//! of connected controllers, so there must be exactly one objc bridge. The
//! graphics/input backends (sokol) cannot import `labelle-core` (no dep edge
//! in the build graph), so instead this module *exports* a tiny C ABI
//! (`labelle_gc_button_down`, `labelle_gc_axis_value`, ...) that the sokol
//! `input.zig` re-declares with `@extern`. Single owner, no duplicated `_gc`
//! state, and the seam is a stable C ABI rather than a Zig module import.
//!
//! ## Detection strategy: poll-and-diff, not NSNotificationCenter blocks
//!
//! GameController exposes connect/disconnect via
//! `GCControllerDidConnectNotification` / `...DidDisconnect`. Observing those
//! requires registering an Objective-C *block* with
//! `-[NSNotificationCenter addObserverForName:object:queue:usingBlock:]`.
//! Synthesising an ObjC block from Zig (the block ABI: isa, flags, an invoke
//! function pointer, a descriptor) is fragile and easy to get subtly wrong.
//!
//! Instead we **poll `+[GCController controllers]` once per `pollEvents`**
//! call and diff it against the previously-seen set keyed by the controller's
//! objc object pointer. New pointers -> `.connected`, vanished pointers ->
//! `.disconnected`. `pollEvents` is already drained every frame by the engine
//! fallback, so detection latency is one frame — identical to what a
//! notification observer would deliver in practice. This is fully
//! deterministic, allocation-free, and has no block-ABI hazard.
//!
//! ## No stable GUID
//!
//! GameController does **not** expose a stable per-device hardware identifier
//! (no USB VID/PID, no Bluetooth GUID). `vendorName` is the only label and is
//! not unique. So `guid` is always left `null`. Reconnection-key consumers
//! must fall back to `slot` + name, same as any GUID-less backend.
//!
//! ## Classification
//!
//! * `GCExtendedGamepad` present -> `.gamepad`.
//! * Only `GCMicroGamepad` present (tvOS Siri Remote) -> `.dpad_remote`.
//! * `type_hint` is best-effort from `vendorName` (DualShock/DualSense ->
//!   `.playstation`, Xbox -> `.xbox`, Switch/Joy-Con -> `.nintendo`);
//!   otherwise `.generic` for real gamepads, `.unknown` for the micro/remote.
//!
//! ## On-device verification (cannot run on CI / a dev Mac)
//!
//! The objc bridge cross-compiles for ios/tvos, but connect/disconnect deltas
//! and live axis values can only be confirmed on real hardware. See the PR
//! checklist for the manual on-device steps.
//!
//! See labelle-toolkit/labelle-assembler#251.

const builtin = @import("builtin");
const std = @import("std");
const source = @import("root.zig");
const GamepadEvent = source.GamepadEvent;
const GamepadDescription = source.GamepadDescription;
const gamepad = @import("../gamepad.zig");

/// Compiled with the real objc bridge only on Apple mobile targets. On every
/// other target (the host that runs `zig build test`) the `Source` collapses
/// to a no-op stub so the contract check in `gamepad_source/root.zig`'s
/// "every platform file compiles" test still passes without dragging libobjc
/// / GameController symbols into a non-Apple link line.
const is_apple_mobile = builtin.target.os.tag == .ios or builtin.target.os.tag == .tvos;

pub const Source = if (is_apple_mobile) GcSource else StubSource;

/// No-op source used when this file is force-referenced on a non-ios/tvos
/// target (the cross-platform compile test in root.zig). Mirrors the frozen
/// contract exactly.
const StubSource = struct {
    pub fn pollEvents(out: []GamepadEvent) usize {
        _ = out;
        return 0;
    }
    pub fn describe(out: []GamepadDescription) usize {
        _ = out;
        return 0;
    }
};

// ── Objective-C runtime primitives ────────────────────────────────
//
// Same `@extern`-to-libobjc pattern the sokol/raylib backends already use for
// Metal/IOSurface interop. libobjc's `objc_msgSend` is variadic in C; each
// distinct call-site signature gets its own typed `@extern` alias so the Zig
// call has a concrete prototype.

const Id = ?*anyopaque;
const SEL = ?*anyopaque;
const Class = ?*anyopaque;

const objc = if (is_apple_mobile) struct {
    extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
    extern "c" fn objc_getClass(name: [*:0]const u8) Class;

    // objc_msgSend variants by signature.
    const msgSend_id = @extern(*const fn (Id, SEL) callconv(.c) Id, .{ .name = "objc_msgSend" });
    const msgSend_id_idx = @extern(*const fn (Id, SEL, usize) callconv(.c) Id, .{ .name = "objc_msgSend" });
    const msgSend_usize = @extern(*const fn (Id, SEL) callconv(.c) usize, .{ .name = "objc_msgSend" });
    const msgSend_bool = @extern(*const fn (Id, SEL) callconv(.c) bool, .{ .name = "objc_msgSend" });
    const msgSend_float = @extern(*const fn (Id, SEL) callconv(.c) f32, .{ .name = "objc_msgSend" });
    const msgSend_cstr = @extern(*const fn (Id, SEL) callconv(.c) ?[*:0]const u8, .{ .name = "objc_msgSend" });
} else struct {};

// ── Selector / class cache ─────────────────────────────────────────

const Sel = struct {
    var loaded: bool = false;

    var cls_GCController: Class = null;
    var controllers: SEL = null; // +[GCController controllers] -> NSArray
    var count: SEL = null; // -[NSArray count] -> NSUInteger
    var objectAtIndex: SEL = null; // -[NSArray objectAtIndex:] -> id
    var extendedGamepad: SEL = null; // -[GCController extendedGamepad] -> id
    var microGamepad: SEL = null; // -[GCController microGamepad] -> id
    var vendorName: SEL = null; // -[GCController vendorName] -> NSString
    var UTF8String: SEL = null; // -[NSString UTF8String] -> const char*

    // GCExtendedGamepad element getters (each -> GCControllerButtonInput or
    // GCControllerDirectionPad).
    var buttonA: SEL = null;
    var buttonB: SEL = null;
    var buttonX: SEL = null;
    var buttonY: SEL = null;
    var leftShoulder: SEL = null;
    var rightShoulder: SEL = null;
    var leftTrigger: SEL = null;
    var rightTrigger: SEL = null;
    var leftThumbstickButton: SEL = null;
    var rightThumbstickButton: SEL = null;
    var buttonMenu: SEL = null;
    var buttonOptions: SEL = null;
    var dpad: SEL = null;
    var leftThumbstick: SEL = null;
    var rightThumbstick: SEL = null;

    // GCControllerButtonInput / GCControllerAxisInput / direction-pad axes.
    var isPressed: SEL = null; // -[GCControllerButtonInput isPressed] -> BOOL
    var btnValue: SEL = null; // -[GCControllerButtonInput value] -> float
    var xAxis: SEL = null; // -[GCControllerDirectionPad xAxis] -> GCControllerAxisInput
    var yAxis: SEL = null; // -[GCControllerDirectionPad yAxis]
    var up: SEL = null; // dpad -> button
    var down: SEL = null;
    var left: SEL = null;
    var right: SEL = null;
    var axisValue: SEL = null; // -[GCControllerAxisInput value] -> float

    fn load() void {
        if (loaded) return;
        loaded = true;
        cls_GCController = objc.objc_getClass("GCController");
        controllers = objc.sel_registerName("controllers");
        count = objc.sel_registerName("count");
        objectAtIndex = objc.sel_registerName("objectAtIndex:");
        extendedGamepad = objc.sel_registerName("extendedGamepad");
        microGamepad = objc.sel_registerName("microGamepad");
        vendorName = objc.sel_registerName("vendorName");
        UTF8String = objc.sel_registerName("UTF8String");

        buttonA = objc.sel_registerName("buttonA");
        buttonB = objc.sel_registerName("buttonB");
        buttonX = objc.sel_registerName("buttonX");
        buttonY = objc.sel_registerName("buttonY");
        leftShoulder = objc.sel_registerName("leftShoulder");
        rightShoulder = objc.sel_registerName("rightShoulder");
        leftTrigger = objc.sel_registerName("leftTrigger");
        rightTrigger = objc.sel_registerName("rightTrigger");
        leftThumbstickButton = objc.sel_registerName("leftThumbstickButton");
        rightThumbstickButton = objc.sel_registerName("rightThumbstickButton");
        buttonMenu = objc.sel_registerName("buttonMenu");
        buttonOptions = objc.sel_registerName("buttonOptions");
        dpad = objc.sel_registerName("dpad");
        leftThumbstick = objc.sel_registerName("leftThumbstick");
        rightThumbstick = objc.sel_registerName("rightThumbstick");

        isPressed = objc.sel_registerName("isPressed");
        btnValue = objc.sel_registerName("value");
        xAxis = objc.sel_registerName("xAxis");
        yAxis = objc.sel_registerName("yAxis");
        up = objc.sel_registerName("up");
        down = objc.sel_registerName("down");
        left = objc.sel_registerName("left");
        right = objc.sel_registerName("right");
        axisValue = objc.sel_registerName("value");
    }
};

// ── Connected-controller registry ──────────────────────────────────
//
// std.BoundedArray was removed in Zig 0.16 — we use a fixed-capacity array
// plus an explicit length instead. `MAX_CONTROLLERS` matches GameController's
// practical simultaneous-connection limit (4 for most profiles); the extra
// headroom is cheap and avoids dropping a controller on a busy tvOS.

const MAX_CONTROLLERS: usize = 8;

/// One tracked controller. `obj` is the objc `GCController*` used both as the
/// identity key (for hotplug diffing) and as the receiver for state queries.
const Controller = struct {
    obj: Id = null,
    slot: u32 = 0,
    source_class: gamepad.SourceClass = .unknown,
};

var tracked: [MAX_CONTROLLERS]Controller = [_]Controller{.{}} ** MAX_CONTROLLERS;
var tracked_len: usize = 0;

/// Monotonic slot allocator. Slots are never reused within a session so a
/// disconnect+reconnect of the same physical pad reads as a *new* slot — the
/// engine treats `slot` as opaque and GameController gives us no stable key to
/// reunify them anyway.
var next_slot: u32 = 0;

/// The actual GC source. Selected into `Source` only on ios/tvos.
const GcSource = struct {
    pub fn init() void {
        Sel.load();
        // Reset the registry. We do NOT emit connect events here — controllers
        // already paired at launch surface on the first `pollEvents` diff,
        // matching how every other pad is reported (the engine drains
        // pollEvents, not init).
        tracked_len = 0;
        next_slot = 0;
    }

    pub fn deinit() void {
        tracked_len = 0;
    }

    /// Diff the live `+[GCController controllers]` array against our registry
    /// and emit connect/disconnect deltas into `out`.
    pub fn pollEvents(out: []GamepadEvent) usize {
        if (out.len == 0) return 0;
        Sel.load();
        const cls = Sel.cls_GCController orelse return 0;

        const arr = objc.msgSend_id(cls, Sel.controllers) orelse return 0;
        const live_count = objc.msgSend_usize(arr, Sel.count);

        var written: usize = 0;

        // Scan every live controller (the full array — do NOT stop at
        // MAX_CONTROLLERS, or a still-connected controller past that index
        // would be treated as absent and flap each frame). Emit `connected`
        // for any not already tracked, but ONLY commit it to `tracked` when we
        // can actually deliver the event. If `out` is full (or we're at
        // capacity) we leave it untracked so the connect re-fires next poll
        // instead of being silently tracked-without-emitting.
        var i: usize = 0;
        while (i < live_count) : (i += 1) {
            const ctrl = objc.msgSend_id_idx(arr, Sel.objectAtIndex, i) orelse continue;

            if (findController(ctrl) == null) {
                if (tracked_len >= MAX_CONTROLLERS) continue;
                if (written >= out.len) continue; // re-detected next poll
                const klass = classify(ctrl);
                const slot = next_slot;
                next_slot += 1;
                tracked[tracked_len] = .{ .obj = ctrl, .slot = slot, .source_class = klass };
                tracked_len += 1;

                out[written] = makeConnected(ctrl, slot, klass);
                written += 1;
            }
        }

        // Sweep: any tracked entry whose objc pointer is no longer in the live
        // array is a disconnect. Liveness is checked against the full live
        // array (not a bounded snapshot) so controllers past MAX_CONTROLLERS
        // don't spuriously disconnect. Compact the array in place; only drop
        // an entry once its `disconnected` event is actually emitted — if `out`
        // is full, keep it tracked so the disconnect re-fires next poll.
        var w: usize = 0;
        var r: usize = 0;
        while (r < tracked_len) : (r += 1) {
            const entry = tracked[r];
            if (isLive(arr, live_count, entry.obj)) {
                tracked[w] = entry;
                w += 1;
            } else if (written < out.len) {
                out[written] = GamepadEvent.disconnected(entry.slot);
                written += 1;
                // dropped (not copied forward)
            } else {
                // Buffer full — keep tracked so we retry the disconnect next
                // poll rather than losing the transition.
                tracked[w] = entry;
                w += 1;
            }
        }
        tracked_len = w;

        return written;
    }

    /// Diagnostic enumeration of the currently-connected controllers.
    pub fn describe(out: []GamepadDescription) usize {
        Sel.load();
        var n: usize = 0;
        var i: usize = 0;
        while (i < tracked_len and n < out.len) : (i += 1) {
            const entry = tracked[i];
            var d = GamepadDescription{
                .slot = entry.slot,
                .connected = true,
                .source_class = entry.source_class,
                .type_hint = typeHintFor(entry.obj, entry.source_class),
                .guid = null,
                .unavailable_reason = .none,
            };
            setNameFromVendor(&d, entry.obj);
            out[n] = d;
            n += 1;
        }
        return n;
    }
};

// ── Helpers (Apple-only — only referenced from GcSource) ───────────

fn findController(ctrl: Id) ?usize {
    var i: usize = 0;
    while (i < tracked_len) : (i += 1) {
        if (tracked[i].obj == ctrl) return i;
    }
    return null;
}

/// Is `ptr` present in the live `+[GCController controllers]` array? Scans the
/// whole array (no MAX_CONTROLLERS bound) so a tracked controller is never
/// falsely reported absent just because it sits past the registry capacity.
fn isLive(arr: Id, live_count: usize, ptr: Id) bool {
    var i: usize = 0;
    while (i < live_count) : (i += 1) {
        if (objc.msgSend_id_idx(arr, Sel.objectAtIndex, i) == ptr) return true;
    }
    return false;
}

/// `.gamepad` when the controller exposes an extended profile, otherwise
/// `.dpad_remote` (tvOS Siri Remote exposes only the micro profile).
fn classify(ctrl: Id) gamepad.SourceClass {
    if (objc.msgSend_id(ctrl, Sel.extendedGamepad) != null) return .gamepad;
    if (objc.msgSend_id(ctrl, Sel.microGamepad) != null) return .dpad_remote;
    return .unknown;
}

fn makeConnected(ctrl: Id, slot: u32, klass: gamepad.SourceClass) GamepadEvent {
    var ev = GamepadEvent{ .kind = .connected, .slot = slot };
    ev.source_class = klass;
    ev.type_hint = typeHintFor(ctrl, klass);
    ev.guid = null; // GameController exposes no stable hardware GUID.
    setEventNameFromVendor(&ev, ctrl);
    return ev;
}

fn vendorNameSlice(ctrl: Id) ?[]const u8 {
    const ns = objc.msgSend_id(ctrl, Sel.vendorName) orelse return null;
    const cstr = objc.msgSend_cstr(ns, Sel.UTF8String) orelse return null;
    return std.mem.span(cstr);
}

fn setEventNameFromVendor(ev: *GamepadEvent, ctrl: Id) void {
    if (vendorNameSlice(ctrl)) |name| ev.setName(name);
}

fn setNameFromVendor(d: *GamepadDescription, ctrl: Id) void {
    if (vendorNameSlice(ctrl)) |name| d.setName(name);
}

/// Best-effort vendor family from the controller's `vendorName`. Apple does
/// not expose VID/PID, so this is a name-substring heuristic only.
fn typeHintFor(ctrl: Id, klass: gamepad.SourceClass) gamepad.TypeHint {
    const name = vendorNameSlice(ctrl) orelse {
        return if (klass == .gamepad) .generic else .unknown;
    };
    if (containsIgnoreCase(name, "dualsense") or
        containsIgnoreCase(name, "dualshock") or
        containsIgnoreCase(name, "playstation")) return .playstation;
    if (containsIgnoreCase(name, "xbox")) return .xbox;
    if (containsIgnoreCase(name, "switch") or
        containsIgnoreCase(name, "joy-con") or
        containsIgnoreCase(name, "joycon") or
        containsIgnoreCase(name, "nintendo")) return .nintendo;
    return if (klass == .gamepad) .generic else .unknown;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (toLower(haystack[i + j]) != toLower(needle[j])) continue :outer;
        }
        return true;
    }
    return false;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// ── State query bridge for the input backend ───────────────────────
//
// Button / axis numbering follows the engine's canonical raylib-compatible
// `GamepadButton` / `GamepadAxis` enums (input_types.zig). The sokol input
// backend forwards its `(gamepad_id, button)` / `(gamepad_id, axis)` u32 pairs
// straight to these symbols.

/// Engine/raylib `GamepadButton` values.
const Button = enum(u32) {
    unknown = 0,
    left_face_up = 1, // dpad up
    left_face_right = 2, // dpad right
    left_face_down = 3, // dpad down
    left_face_left = 4, // dpad left
    right_face_up = 5, // Y / top face
    right_face_right = 6, // B / right face
    right_face_down = 7, // A / bottom face
    right_face_left = 8, // X / left face
    left_trigger_1 = 9, // L1 / left shoulder
    left_trigger_2 = 10, // L2 / left trigger
    right_trigger_1 = 11, // R1 / right shoulder
    right_trigger_2 = 12, // R2 / right trigger
    middle_left = 13, // Options / View
    middle = 14, // (no GC equivalent — home/guide not in profile)
    middle_right = 15, // Menu / Start
    left_thumb = 16, // L3
    right_thumb = 17, // R3
    _,
};

/// Engine/raylib `GamepadAxis` values.
const Axis = enum(u32) {
    left_x = 0,
    left_y = 1,
    right_x = 2,
    right_y = 3,
    left_trigger = 4,
    right_trigger = 5,
    _,
};

/// Resolve a slot to its live `GCController*`, or null if not connected.
fn controllerForSlot(slot: u32) Id {
    var i: usize = 0;
    while (i < tracked_len) : (i += 1) {
        if (tracked[i].slot == slot) return tracked[i].obj;
    }
    return null;
}

/// `extendedGamepad` for a slot, or null when the slot is a micro/remote or
/// not connected. State queries only support the extended profile (the issue
/// scopes button/axis state to GCExtendedGamepad).
fn extendedProfile(slot: u32) Id {
    const ctrl = controllerForSlot(slot) orelse return null;
    return objc.msgSend_id(ctrl, Sel.extendedGamepad);
}

/// The `GCControllerButtonInput*` for a face/shoulder/trigger/thumb button on
/// the extended profile, or null. D-pad directions are handled separately.
fn buttonInput(profile: Id, btn: Button) Id {
    const sel: SEL = switch (btn) {
        .right_face_down => Sel.buttonA,
        .right_face_right => Sel.buttonB,
        .right_face_left => Sel.buttonX,
        .right_face_up => Sel.buttonY,
        .left_trigger_1 => Sel.leftShoulder,
        .left_trigger_2 => Sel.leftTrigger,
        .right_trigger_1 => Sel.rightShoulder,
        .right_trigger_2 => Sel.rightTrigger,
        .left_thumb => Sel.leftThumbstickButton,
        .right_thumb => Sel.rightThumbstickButton,
        .middle_left => Sel.buttonOptions,
        .middle_right => Sel.buttonMenu,
        else => return null,
    };
    if (sel == null) return null;
    return objc.msgSend_id(profile, sel);
}

/// The `GCControllerButtonInput*` for a d-pad direction, via `-[profile dpad]`.
fn dpadButton(profile: Id, btn: Button) Id {
    const pad = objc.msgSend_id(profile, Sel.dpad) orelse return null;
    const sel: SEL = switch (btn) {
        .left_face_up => Sel.up,
        .left_face_down => Sel.down,
        .left_face_left => Sel.left,
        .left_face_right => Sel.right,
        else => return null,
    };
    if (sel == null) return null;
    return objc.msgSend_id(pad, sel);
}

fn isButtonDownImpl(slot: u32, button_raw: u32) bool {
    if (comptime !is_apple_mobile) return false;
    Sel.load();
    const profile = extendedProfile(slot) orelse return false;
    const btn: Button = @enumFromInt(button_raw);
    const input = switch (btn) {
        .left_face_up, .left_face_down, .left_face_left, .left_face_right => dpadButton(profile, btn),
        else => buttonInput(profile, btn),
    } orelse return false;
    return objc.msgSend_bool(input, Sel.isPressed);
}

fn axisValueImpl(slot: u32, axis_raw: u32) f32 {
    if (comptime !is_apple_mobile) return 0;
    Sel.load();
    const profile = extendedProfile(slot) orelse return 0;
    const axis: Axis = @enumFromInt(axis_raw);
    switch (axis) {
        .left_x => return dirAxis(profile, Sel.leftThumbstick, Sel.xAxis),
        .left_y => return dirAxis(profile, Sel.leftThumbstick, Sel.yAxis),
        .right_x => return dirAxis(profile, Sel.rightThumbstick, Sel.xAxis),
        .right_y => return dirAxis(profile, Sel.rightThumbstick, Sel.yAxis),
        .left_trigger => {
            const t = objc.msgSend_id(profile, Sel.leftTrigger) orelse return 0;
            return objc.msgSend_float(t, Sel.btnValue);
        },
        .right_trigger => {
            const t = objc.msgSend_id(profile, Sel.rightTrigger) orelse return 0;
            return objc.msgSend_float(t, Sel.btnValue);
        },
        else => return 0,
    }
}

/// Read one axis of a `GCControllerDirectionPad` (thumbstick) on the profile.
fn dirAxis(profile: Id, stick_sel: SEL, axis_sel: SEL) f32 {
    const stick = objc.msgSend_id(profile, stick_sel) orelse return 0;
    const ax = objc.msgSend_id(stick, axis_sel) orelse return 0;
    return objc.msgSend_float(ax, Sel.axisValue);
}

// ── Exported C ABI consumed by the sokol input backend ─────────────
//
// These are the seam the sokol `input.zig` re-declares with `@extern` (gated
// to ios/tvos). They are only emitted on Apple mobile targets; on the host
// test build they are absent, which is fine because the sokol backend's
// extern declarations are likewise gated and the core test binary never
// references them.

comptime {
    if (is_apple_mobile) {
        @export(&gcButtonDown, .{ .name = "labelle_gc_button_down", .linkage = .strong });
        @export(&gcAxisValue, .{ .name = "labelle_gc_axis_value", .linkage = .strong });
        @export(&gcConnected, .{ .name = "labelle_gc_connected", .linkage = .strong });
    }
}

/// `bool labelle_gc_button_down(uint32_t slot, uint32_t button)`
fn gcButtonDown(slot: u32, button: u32) callconv(.c) bool {
    return isButtonDownImpl(slot, button);
}

/// `float labelle_gc_axis_value(uint32_t slot, uint32_t axis)`
fn gcAxisValue(slot: u32, axis: u32) callconv(.c) f32 {
    return axisValueImpl(slot, axis);
}

/// `bool labelle_gc_connected(uint32_t slot)` — slot currently has a live
/// controller. (Backs `isGamepadAvailable` in the input backend.)
fn gcConnected(slot: u32) callconv(.c) bool {
    if (comptime !is_apple_mobile) return false;
    return controllerForSlot(slot) != null;
}

// ── Tests (host target) ────────────────────────────────────────────
//
// On the host (non-Apple) build, `Source` is the stub. We assert the frozen
// contract still holds and that the button/axis enum tables line up with the
// engine's canonical values — that table is the only thing testable without a
// device.

test "host build: Source satisfies the frozen no-op contract" {
    var ev: [4]GamepadEvent = undefined;
    if (@hasDecl(Source, "init")) Source.init();
    defer if (@hasDecl(Source, "deinit")) Source.deinit();
    try std.testing.expectEqual(@as(usize, 0), Source.pollEvents(&ev));
    var d: [4]GamepadDescription = undefined;
    try std.testing.expectEqual(@as(usize, 0), Source.describe(&d));
}

test "button enum matches engine canonical GamepadButton values" {
    try std.testing.expectEqual(@as(u32, 7), @intFromEnum(Button.right_face_down)); // A
    try std.testing.expectEqual(@as(u32, 6), @intFromEnum(Button.right_face_right)); // B
    try std.testing.expectEqual(@as(u32, 8), @intFromEnum(Button.right_face_left)); // X
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(Button.right_face_up)); // Y
    try std.testing.expectEqual(@as(u32, 15), @intFromEnum(Button.middle_right)); // menu
    try std.testing.expectEqual(@as(u32, 16), @intFromEnum(Button.left_thumb));
}

test "axis enum matches engine canonical GamepadAxis values" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(Axis.left_x));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(Axis.right_y));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(Axis.right_trigger));
}

test "containsIgnoreCase vendor-name heuristic" {
    try std.testing.expect(containsIgnoreCase("DualSense Wireless Controller", "dualsense"));
    try std.testing.expect(containsIgnoreCase("Xbox Wireless Controller", "XBOX"));
    try std.testing.expect(!containsIgnoreCase("Generic Gamepad", "switch"));
}
