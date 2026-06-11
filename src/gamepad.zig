//! Cross-backend gamepad/controller event contract — **Wave 0 foundation**.
//!
//! This module freezes the value types that flow across the gamepad
//! hotplug/event boundary. Everything here is intentionally COPY-only:
//! `GamepadEvent` and `GamepadDescription` contain no borrowed slices or
//! pointers, so they can be memcpy'd through a fixed-size ring buffer
//! without lifetime concerns. Backends (raylib, sdl, sokol, ...) and the
//! per-OS `gamepad_source` modules produce these; the engine drains them.
//!
//! See labelle-toolkit/labelle-core#18.

const std = @import("std");

/// Maximum bytes stored inline for a gamepad's human-readable name.
/// The buffer is NUL-terminated (`[NAME_CAPACITY:0]u8`) so it can also be
/// passed to C APIs; `name_len` is the authoritative length.
pub const NAME_CAPACITY: usize = 63;

/// Best-guess vendor family of a device, for glyph/prompt selection.
/// Backends set this when they can identify the device; otherwise `.unknown`.
pub const TypeHint = enum(u8) {
    unknown,
    xbox,
    playstation,
    nintendo,
    generic,
};

/// Best-guess vendor family from a human-readable device name string.
///
/// Shared name→type classifier for any source that only has a name to go on
/// (Android `InputDevice.getName()`, raylib's `GetGamepadName`, the WebGamepad
/// `id` string). Backends with a stable USB vendor id (Linux evdev, iOS GC
/// profile) should classify from that instead — this is the name-only path.
///
/// Matching is case-insensitive substring. A non-empty name that matches no
/// known family is `.generic`; an empty name is `.unknown`.
pub fn typeHintFromName(name: []const u8) TypeHint {
    if (containsIgnoreCase(name, "xbox") or
        containsIgnoreCase(name, "microsoft")) return .xbox;
    // Nintendo BEFORE the PlayStation block: the latter treats the generic
    // "wireless controller" as PlayStation, but Nintendo pads commonly report
    // names like "Nintendo Switch Wireless Controller" — match the specific
    // brand keywords first so they don't fall into the generic PS bucket.
    if (containsIgnoreCase(name, "nintendo") or
        containsIgnoreCase(name, "switch") or
        containsIgnoreCase(name, "joy-con") or
        containsIgnoreCase(name, "pro controller")) return .nintendo;
    if (containsIgnoreCase(name, "playstation") or
        containsIgnoreCase(name, "dualsense") or
        containsIgnoreCase(name, "dualshock") or
        containsIgnoreCase(name, "sony") or
        containsIgnoreCase(name, "wireless controller")) return .playstation;
    if (name.len > 0) return .generic;
    return .unknown;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

/// What kind of physical device produced the event. Distinguishes a real
/// game controller from a TV / set-top "d-pad remote" (Android TV, tvOS),
/// which should usually be treated differently by menus.
pub const SourceClass = enum(u8) {
    gamepad,
    dpad_remote,
    unknown,
};

/// Why a device could not be made available, for diagnostics/logging.
/// `.none` means the device is usable. Linux evdev permission failures
/// surface as `.permission_denied`; platforms lacking any source report
/// `.unsupported`.
pub const UnavailableReason = enum(u8) {
    none,
    permission_denied,
    unsupported,
    not_present,
    init_failed,
};

/// A hotplug (connect/disconnect) event. COPY-only — no borrowed memory.
///
/// `slot` is the backend-assigned device index (also exposed as `id` for
/// backward-compat with the engine's current `{ id: u32 }` payload — they
/// alias the same value). `name`/`name_len` carry an inline bounded string
/// (empty when the backend can't supply one). `guid` is a stable
/// reconnection key when the backend exposes one.
pub const GamepadEvent = struct {
    pub const Kind = enum(u8) { connected, disconnected };

    kind: Kind,

    /// Backend-assigned device slot/index.
    slot: u32,

    /// Inline, NUL-terminated device name buffer. Use `setName`/`nameSlice`
    /// instead of touching these directly. Empty (`name_len == 0`) if unknown.
    name: [NAME_CAPACITY:0]u8 = [_:0]u8{0} ** NAME_CAPACITY,
    name_len: u8 = 0,

    /// Stable per-device identifier (e.g. SDL joystick GUID) where available.
    guid: ?[16]u8 = null,

    source_class: SourceClass = .unknown,
    type_hint: TypeHint = .unknown,

    /// Backward-compat alias for `slot`. The engine's legacy event payload
    /// used `id: u32`; new producers should set `slot`, this just mirrors it.
    pub inline fn id(self: GamepadEvent) u32 {
        return self.slot;
    }

    /// Borrow the device name as a slice (valid for the lifetime of `self`).
    pub fn nameSlice(self: *const GamepadEvent) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Copy `text` into the inline name buffer, truncating to `NAME_CAPACITY`.
    /// Always leaves the buffer NUL-terminated.
    pub fn setName(self: *GamepadEvent, text: []const u8) void {
        const n = @min(text.len, NAME_CAPACITY);
        @memcpy(self.name[0..n], text[0..n]);
        // Zero the remainder so the buffer stays a clean, comparable value.
        @memset(self.name[n..], 0);
        self.name_len = @intCast(n);
    }

    /// Convenience constructor for a connect event with a name.
    pub fn connected(slot: u32, name_text: []const u8) GamepadEvent {
        var ev = GamepadEvent{ .kind = .connected, .slot = slot };
        ev.setName(name_text);
        return ev;
    }

    /// Convenience constructor for a disconnect event.
    pub fn disconnected(slot: u32) GamepadEvent {
        return .{ .kind = .disconnected, .slot = slot };
    }
};

/// Diagnostic snapshot of a currently-visible device. COPY-only.
///
/// Produced by `describeGamepads` for logging / debug UIs. Unlike
/// `GamepadEvent` this is a *state* snapshot, not a hotplug delta, and it
/// carries an `unavailable_reason` so a device that is detected but cannot
/// be opened (e.g. Linux permission denied) can still be reported.
pub const GamepadDescription = struct {
    slot: u32,
    connected: bool = false,

    name: [NAME_CAPACITY:0]u8 = [_:0]u8{0} ** NAME_CAPACITY,
    name_len: u8 = 0,

    guid: ?[16]u8 = null,
    source_class: SourceClass = .unknown,
    type_hint: TypeHint = .unknown,

    /// `.none` when usable; otherwise why the device can't be opened.
    unavailable_reason: UnavailableReason = .none,

    pub fn nameSlice(self: *const GamepadDescription) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setName(self: *GamepadDescription, text: []const u8) void {
        const n = @min(text.len, NAME_CAPACITY);
        @memcpy(self.name[0..n], text[0..n]);
        @memset(self.name[n..], 0);
        self.name_len = @intCast(n);
    }
};

test "GamepadEvent is copy-only (no pointers/slices in layout)" {
    // A pure-value type is trivially copyable; assert there are no slice/
    // pointer fields by checking the type has a well-defined byte size and
    // round-trips through a byte copy.
    const a = GamepadEvent.connected(2, "Xbox Wireless Controller");
    var bytes: [@sizeOf(GamepadEvent)]u8 = undefined;
    @memcpy(&bytes, std.mem.asBytes(&a));
    var b: GamepadEvent = undefined;
    @memcpy(std.mem.asBytes(&b), &bytes);
    try std.testing.expectEqual(@as(u32, 2), b.slot);
    try std.testing.expectEqual(@as(u32, 2), b.id());
    try std.testing.expectEqualStrings("Xbox Wireless Controller", b.nameSlice());
}

test "setName truncates to NAME_CAPACITY and stays NUL-terminated" {
    var ev = GamepadEvent{ .kind = .connected, .slot = 0 };
    const long = "a" ** 200;
    ev.setName(long);
    try std.testing.expectEqual(@as(usize, NAME_CAPACITY), ev.nameSlice().len);
    try std.testing.expectEqual(@as(u8, 0), ev.name[NAME_CAPACITY]); // sentinel intact
}

test "typeHintFromName classifies known vendor families (name-only path)" {
    try std.testing.expectEqual(TypeHint.xbox, typeHintFromName("Xbox Wireless Controller"));
    try std.testing.expectEqual(TypeHint.xbox, typeHintFromName("XBOX 360 For Windows"));
    try std.testing.expectEqual(TypeHint.xbox, typeHintFromName("Microsoft X-Box pad"));
    try std.testing.expectEqual(TypeHint.playstation, typeHintFromName("Sony DualSense Wireless Controller"));
    try std.testing.expectEqual(TypeHint.playstation, typeHintFromName("PLAYSTATION(R)3 Controller"));
    try std.testing.expectEqual(TypeHint.playstation, typeHintFromName("Wireless Controller"));
    try std.testing.expectEqual(TypeHint.nintendo, typeHintFromName("Nintendo Switch Pro Controller"));
    try std.testing.expectEqual(TypeHint.nintendo, typeHintFromName("Joy-Con (L)"));
    // Nintendo brand keywords must win over the generic "wireless controller"
    // PlayStation fallback (regression: this used to classify as playstation).
    try std.testing.expectEqual(TypeHint.nintendo, typeHintFromName("Nintendo Switch Wireless Controller"));
    try std.testing.expectEqual(TypeHint.generic, typeHintFromName("Generic USB Joystick"));
    try std.testing.expectEqual(TypeHint.unknown, typeHintFromName(""));
}

test "disconnected constructor" {
    const ev = GamepadEvent.disconnected(3);
    try std.testing.expectEqual(GamepadEvent.Kind.disconnected, ev.kind);
    try std.testing.expectEqual(@as(u32, 3), ev.slot);
    try std.testing.expectEqual(@as(usize, 0), ev.nameSlice().len);
}
