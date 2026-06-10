//! WebAssembly gamepad **detection** source (browser HTML5 Gamepad API).
//!
//! Detection/identity only. The browser fires `gamepadconnected` /
//! `gamepaddisconnected` on `window` when a pad becomes usable (the spec
//! requires a user gesture / button press before a pad is exposed). A tiny JS
//! shim (shipped by the wasm host / assembler) listens for those events and
//! forwards them into this module via the `labelle_gamepad_*` imports below;
//! we turn them into `GamepadEvent`s and buffer them in a ring until the
//! engine drains `pollEvents`.
//!
//! Identity mapping:
//!   * `Gamepad.index`  → `slot`
//!   * `Gamepad.id`     → `name` (the browser's "Vendor (STANDARD GAMEPAD ...)"
//!                         string; we also sniff it for a `type_hint`)
//!   * a 16-byte GUID is derived from a hash of `Gamepad.id` so a controller
//!     keeps a stable reconnection key within a session (the Gamepad API
//!     exposes no raw vendor/product ids).
//!
//! ## JS <-> wasm contract
//!
//! The JS side calls these wasm exports (NOT imports — wasm is the callee):
//!
//! ```js
//! // on 'gamepadconnected':
//! const id = enc.encode(e.gamepad.id);
//! const ptr = inst.exports.labelle_gamepad_name_buffer();
//! new Uint8Array(memory.buffer, ptr, id.length).set(id);
//! inst.exports.labelle_gamepad_connected(e.gamepad.index, id.length);
//! // on 'gamepaddisconnected':
//! inst.exports.labelle_gamepad_disconnected(e.gamepad.index);
//! ```
//!
//! Keeping wasm as the callee (exports) avoids needing an `extern` JS import
//! at instantiation time, which would force every host to provide the symbol
//! even when it has no gamepad shim. The exports are inert if never called.
//!
//! TODO(assembler#249): ship the JS shim from the wasm host template and wire
//! it to these exports (assembler side). Verify in a browser (PR checklist).

const builtin = @import("builtin");
const std = @import("std");

const source = @import("root.zig");
const GamepadEvent = source.GamepadEvent;
const GamepadDescription = source.GamepadDescription;
const gamepad = @import("../gamepad.zig");

const is_wasm = builtin.target.cpu.arch.isWasm();

pub const Source = if (is_wasm) WasmSource else FallbackSource;

/// Non-wasm stand-in so the file type-checks when force-referenced on the host
/// (see gamepad_source/root.zig's "every platform file compiles" test).
const FallbackSource = struct {
    pub fn pollEvents(out: []GamepadEvent) usize {
        _ = out;
        return 0;
    }
    pub fn describe(out: []GamepadDescription) usize {
        _ = out;
        return 0;
    }
};

const RING_CAPACITY = 32;
const MAX_TRACKED = 16;

const Tracked = struct {
    slot: u32 = 0,
    guid: [16]u8 = [_]u8{0} ** 16,
    name: [gamepad.NAME_CAPACITY:0]u8 = [_:0]u8{0} ** gamepad.NAME_CAPACITY,
    name_len: u8 = 0,
    type_hint: gamepad.TypeHint = .unknown,
    in_use: bool = false,
};

const WasmSource = struct {
    var ring: [RING_CAPACITY]GamepadEvent = undefined;
    var ring_head: usize = 0;
    var ring_tail: usize = 0;
    var ring_count: usize = 0;

    var tracked: [MAX_TRACKED]Tracked = [_]Tracked{.{}} ** MAX_TRACKED;

    /// Staging buffer the JS shim writes the UTF-8 `Gamepad.id` into before
    /// calling `labelle_gamepad_connected`.
    var name_buf: [gamepad.NAME_CAPACITY]u8 = undefined;

    pub fn pollEvents(out: []GamepadEvent) usize {
        var written: usize = 0;
        while (written < out.len and ring_count > 0) : (written += 1) {
            out[written] = ring[ring_head];
            ring_head = (ring_head + 1) % RING_CAPACITY;
            ring_count -= 1;
        }
        return written;
    }

    pub fn describe(out: []GamepadDescription) usize {
        var n: usize = 0;
        for (&tracked) |*t| {
            if (n >= out.len) break;
            if (!t.in_use) continue;
            var d = GamepadDescription{
                .slot = t.slot,
                .connected = true,
                .guid = t.guid,
                .source_class = .gamepad,
                .type_hint = t.type_hint,
            };
            d.setName(t.name[0..t.name_len]);
            out[n] = d;
            n += 1;
        }
        return n;
    }

    fn pushEvent(ev: GamepadEvent) void {
        if (ring_count == RING_CAPACITY) {
            ring_head = (ring_head + 1) % RING_CAPACITY;
            ring_count -= 1;
        }
        ring[ring_tail] = ev;
        ring_tail = (ring_tail + 1) % RING_CAPACITY;
        ring_count += 1;
    }

    fn findBySlot(slot: u32) ?usize {
        for (&tracked, 0..) |*t, i| {
            if (t.in_use and t.slot == slot) return i;
        }
        return null;
    }

    fn allocSlot() ?usize {
        for (&tracked, 0..) |*t, i| {
            if (!t.in_use) return i;
        }
        return null;
    }
};

// ── wasm exports the JS shim calls ─────────────────────────────────────
// Only emitted on a wasm target. `export` makes them visible to the host;
// they are inert (never invoked) if the host ships no gamepad shim.

comptime {
    if (is_wasm) {
        @export(&labelle_gamepad_name_buffer, .{ .name = "labelle_gamepad_name_buffer" });
        @export(&labelle_gamepad_connected, .{ .name = "labelle_gamepad_connected" });
        @export(&labelle_gamepad_disconnected, .{ .name = "labelle_gamepad_disconnected" });
    }
}

/// Returns the address of the name staging buffer so JS can copy the
/// `Gamepad.id` UTF-8 bytes into it (up to `NAME_CAPACITY`) before calling
/// `labelle_gamepad_connected`.
fn labelle_gamepad_name_buffer() callconv(.c) [*]u8 {
    return &WasmSource.name_buf;
}

/// JS `gamepadconnected` handler entry point. `index` is `Gamepad.index`,
/// `name_len` the number of bytes written into the name buffer.
fn labelle_gamepad_connected(index: u32, name_len: u32) callconv(.c) void {
    const n = @min(@as(usize, name_len), gamepad.NAME_CAPACITY);
    const name = WasmSource.name_buf[0..n];

    const idx = WasmSource.findBySlot(index) orelse WasmSource.allocSlot() orelse return;
    const t = &WasmSource.tracked[idx];
    t.* = .{};
    t.in_use = true;
    t.slot = index;
    t.guid = makeGuid(name);
    t.type_hint = typeHintFromId(name);
    const cap = @min(name.len, gamepad.NAME_CAPACITY);
    @memcpy(t.name[0..cap], name[0..cap]);
    @memset(t.name[cap..], 0);
    t.name_len = @intCast(cap);

    var ev = GamepadEvent{
        .kind = .connected,
        .slot = index,
        .guid = t.guid,
        .source_class = .gamepad,
        .type_hint = t.type_hint,
    };
    ev.setName(name);
    WasmSource.pushEvent(ev);
}

/// JS `gamepaddisconnected` handler entry point.
fn labelle_gamepad_disconnected(index: u32) callconv(.c) void {
    var ev = GamepadEvent{ .kind = .disconnected, .slot = index, .source_class = .gamepad };
    if (WasmSource.findBySlot(index)) |idx| {
        const t = &WasmSource.tracked[idx];
        ev.guid = t.guid;
        ev.setName(t.name[0..t.name_len]);
        t.* = .{};
    }
    WasmSource.pushEvent(ev);
}

// ── pure helpers (host-testable) ───────────────────────────────────────

/// Derive a stable 16-byte GUID from the browser's `Gamepad.id` string. The
/// Gamepad API exposes no raw vendor/product ids, so a hash of the id is the
/// only stable per-device key available; a controller keeps the same GUID
/// across reconnects within a session.
fn makeGuid(id: []const u8) [16]u8 {
    var guid: [16]u8 = [_]u8{0} ** 16;
    // Two independent hashes fill the 16 bytes for a wider distribution.
    const lo = std.hash.Fnv1a_64.hash(id);
    var seeded: [1]u8 = .{0x5a};
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(&seeded);
    hasher.update(id);
    const hi = hasher.final();
    std.mem.writeInt(u64, guid[0..8], lo, .little);
    std.mem.writeInt(u64, guid[8..16], hi, .little);
    return guid;
}

/// Sniff a vendor family out of the Gamepad.id string for glyph selection.
/// Chrome/Firefox ids look like e.g.
/// "Xbox Wireless Controller (STANDARD GAMEPAD Vendor: 045e Product: 02fd)".
fn typeHintFromId(id: []const u8) gamepad.TypeHint {
    if (containsAnyAscii(id, &.{ "Xbox", "045e", "Microsoft" })) return .xbox;
    if (containsAnyAscii(id, &.{ "DualSense", "DualShock", "054c", "Sony", "PLAYSTATION", "PS4", "PS5" })) return .playstation;
    if (containsAnyAscii(id, &.{ "Nintendo", "057e", "Joy-Con", "Pro Controller" })) return .nintendo;
    if (id.len == 0) return .unknown;
    return .generic;
}

fn containsAnyAscii(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (indexOfIgnoreCase(haystack, n) != null) return true;
    }
    return false;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

// ── tests (host) ───────────────────────────────────────────────────────

test "makeGuid is stable and id-sensitive" {
    const a = makeGuid("Xbox Wireless Controller (045e)");
    const b = makeGuid("Xbox Wireless Controller (045e)");
    const c = makeGuid("DualSense Wireless Controller (054c)");
    try std.testing.expectEqual(a, b);
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
}

test "typeHintFromId classifies common vendor strings" {
    try std.testing.expectEqual(gamepad.TypeHint.xbox, typeHintFromId("Xbox Wireless Controller (STANDARD GAMEPAD Vendor: 045e Product: 02fd)"));
    try std.testing.expectEqual(gamepad.TypeHint.playstation, typeHintFromId("DualSense Wireless Controller (Vendor: 054c)"));
    try std.testing.expectEqual(gamepad.TypeHint.nintendo, typeHintFromId("Pro Controller (Vendor: 057e)"));
    try std.testing.expectEqual(gamepad.TypeHint.generic, typeHintFromId("Generic USB Joystick"));
    try std.testing.expectEqual(gamepad.TypeHint.unknown, typeHintFromId(""));
}
