//! Android gamepad event source (sokol/native) — **detection only**.
//!
//! Detects controller hotplug and identity via JNI, distinguishing TV
//! "d-pad remotes" from real gamepads. This file implements DETECTION /
//! REMOVAL / IDENTITY only (labelle-assembler#248). Button/axis *state*
//! is a separate concern tracked by #250 — we never read it here.
//!
//! ## Design (JNI through sokol's ANativeActivity)
//!
//! sokol exposes the running Activity via `sapp_android_get_native_activity()`
//! (Zig: `sokol.app.androidGetNativeActivity()`), which returns an
//! `ANativeActivity*`. From there we reach:
//!   - `ANativeActivity.env`   → JNIEnv* (the sokol main/Looper thread)
//!   - `ANativeActivity.clazz` → the Activity object (a Context)
//!
//! With the JNIEnv we:
//!   1. Look up the `InputManager` system service via
//!      `Context.getSystemService(Context.INPUT_SERVICE)`.
//!   2. Enumerate at startup with `InputManager.getInputDeviceIds()` and
//!      synthesize a `.connected` event per gamepad/joystick device.
//!   3. Register an `InputManager.InputDeviceListener`
//!      (onInputDeviceAdded / onInputDeviceRemoved / onInputDeviceChanged)
//!      so subsequent hotplug deltas arrive as callbacks.
//!
//! For each device we derive a `GamepadEvent`:
//!   - `guid`         ← 16-byte hash of `InputDevice.getDescriptor()`
//!   - `name`         ← `InputDevice.getName()`
//!   - `source_class` ← `InputDevice.getSources()`:
//!         SOURCE_GAMEPAD / SOURCE_JOYSTICK → `.gamepad`
//!         SOURCE_DPAD-only / remote        → `.dpad_remote`
//!   - `slot`         ← the Android device id (stable while connected)
//!
//! ## Threading
//!
//! `InputDeviceListener` callbacks fire on the thread whose `Looper` was
//! current at registration time (sokol's main/Looper thread). `pollEvents`
//! is called from the engine's update thread. We marshal between them with
//! a fixed-size, lock-protected ring buffer: callbacks `push`, `pollEvents`
//! `drain`s. The buffer holds COPY-only `GamepadEvent`s, matching the
//! contract's memcpy-through-a-ring design.
//!
//! ## Host / cross-compile note
//!
//! `gamepad_source/root.zig` force-references this file and calls
//! `pollEvents` on the *host* target for its contract test. Every JNI /
//! `extern` reference is therefore gated behind `comptime is_android`, so on
//! non-Android targets this file compiles to a pure `return 0` with no
//! unresolved symbols. The `extern fn sapp_android_get_native_activity` is
//! provided by sokol_clib at link time on the Android target only.

const std = @import("std");
const builtin = @import("builtin");

const source = @import("root.zig");
const GamepadEvent = source.GamepadEvent;
const GamepadDescription = source.GamepadDescription;

/// True only when building for an Android target. Per project convention
/// there is no `Os.Tag.android` / `isAndroid()`; detect via the abi.
const is_android = builtin.target.abi == .android or builtin.target.abi == .androideabi;

// ── Android source-class bit flags (android.view.InputDevice) ───────────
// Mirrors the SOURCE_* constants. A device's `getSources()` is a bitmask;
// the low byte is the broad class, higher bits are specific sources.
const SOURCE_DPAD: i32 = 0x00000201;
const SOURCE_GAMEPAD: i32 = 0x00000401;
const SOURCE_JOYSTICK: i32 = 0x01000010;

/// Classify a device from its `InputDevice.getSources()` bitmask.
/// A real controller (gamepad/joystick bits) wins over a bare d-pad; a
/// device exposing only d-pad (TV remote, set-top box) is `.dpad_remote`.
fn classifySources(sources: i32) source.SourceClass {
    if ((sources & SOURCE_GAMEPAD) == SOURCE_GAMEPAD) return .gamepad;
    if ((sources & SOURCE_JOYSTICK) == SOURCE_JOYSTICK) return .gamepad;
    if ((sources & SOURCE_DPAD) == SOURCE_DPAD) return .dpad_remote;
    return .unknown;
}

/// Hash a device descriptor string into a stable 16-byte GUID. The Android
/// descriptor is a stable per-physical-device string, so a fixed hash gives
/// a reconnection key compatible with the contract's `guid: ?[16]u8`.
fn descriptorGuid(descriptor: []const u8) [16]u8 {
    var out: [16]u8 = undefined;
    // Two independent 64-bit hashes → 16 bytes. Wyhash with distinct seeds
    // is cheap and well-distributed; this is an identity key, not crypto.
    const lo = std.hash.Wyhash.hash(0x9E3779B97F4A7C15, descriptor);
    const hi = std.hash.Wyhash.hash(0xC2B2AE3D27D4EB4F, descriptor);
    std.mem.writeInt(u64, out[0..8], lo, .little);
    std.mem.writeInt(u64, out[8..16], hi, .little);
    return out;
}

// ── Thread-safe ring buffer (callback thread → pollEvents) ──────────────
//
// Single-producer (Looper callback thread) / single-consumer (engine update
// thread). A mutex keeps it simple and correct; the event rate is hotplug,
// not per-frame, so contention is irrelevant. On overflow we drop the
// oldest event (advance `head`) — a missed connect/disconnect self-heals on
// the next enumeration far more gracefully than blocking the Looper thread.
const RING_CAPACITY = 64;

const EventRing = struct {
    buf: [RING_CAPACITY]GamepadEvent = undefined,
    head: usize = 0,
    len: usize = 0,
    mutex: std.Thread.Mutex = .{},

    /// Drop all queued events. Used on deinit so a later re-init can't observe
    /// hotplug deltas that were queued before/during teardown.
    fn clear(self: *EventRing) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.head = 0;
        self.len = 0;
    }

    fn push(self: *EventRing, ev: GamepadEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == RING_CAPACITY) {
            // Drop oldest to make room (overwrite-on-full).
            self.head = (self.head + 1) % RING_CAPACITY;
            self.len -= 1;
        }
        const tail = (self.head + self.len) % RING_CAPACITY;
        self.buf[tail] = ev;
        self.len += 1;
    }

    /// Drain up to `out.len` events FIFO; returns the count written.
    fn drain(self: *EventRing, out: []GamepadEvent) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(out.len, self.len);
        for (0..n) |i| {
            out[i] = self.buf[(self.head + i) % RING_CAPACITY];
        }
        self.head = (self.head + n) % RING_CAPACITY;
        self.len -= n;
        return n;
    }
};

var ring: EventRing = .{};

// ════════════════════════════════════════════════════════════════════════
// Android-only JNI layer. All `extern` references live behind `is_android`
// so non-Android targets never reference these symbols.
// ════════════════════════════════════════════════════════════════════════

const jni = if (is_android) struct {
    // Minimal ANativeActivity layout. We only need `vm`, `env` and `clazz`,
    // but the struct must match the NDK ABI up to the fields we read, so we
    // declare the full prefix. From <android/native_activity.h>.
    const ANativeActivity = extern struct {
        callbacks: ?*anyopaque,
        vm: ?*JavaVM,
        env: ?*JNIEnv,
        clazz: jobject, // the Activity instance (a Context)
        internalDataPath: ?[*:0]const u8,
        externalDataPath: ?[*:0]const u8,
        sdkVersion: i32,
        instance: ?*anyopaque,
        assetManager: ?*anyopaque,
        obbPath: ?[*:0]const u8,
    };

    // Opaque JNI handle types.
    const jobject = ?*anyopaque;
    const jclass = jobject;
    const jmethodID = ?*anyopaque;
    const jstring = jobject;
    const jintArray = jobject;
    const JavaVM = opaque {};

    // JNIEnv is a pointer to a function table; we declare only the calls we
    // use, by index, through the standard `(*env)->Fn(env, ...)` indirection.
    // Rather than transcribe the whole 200+ entry table we declare the few
    // function pointers we need at their canonical offsets via the opaque
    // env + helper externs implemented in the JNI glue C file shipped by the
    // assembler (see backends/sokol/src/android_gamepad_jni.c). Keeping the
    // raw vtable walking in C avoids hand-maintaining the JNINativeInterface
    // struct in Zig and keeps this file ABI-robust across NDK versions.
    const JNIEnv = opaque {};

    // ── Glue entry points (implemented in the assembler's C JNI file) ────
    // These wrap the InputManager / InputDevice reflection so the Zig side
    // stays small and ABI-stable. They are plain C functions, not JNI
    // natives, invoked from the sokol main thread during init().
    //
    //   labelle_android_gamepad_init(activity) → registers the listener and
    //       enumerates existing devices; pushes events via the callbacks
    //       below.
    //   labelle_android_gamepad_shutdown()     → unregisters the listener.
    extern fn labelle_android_gamepad_init(activity: ?*const anyopaque) callconv(.c) void;
    extern fn labelle_android_gamepad_shutdown() callconv(.c) void;

    // sokol's accessor for the running Activity (provided by sokol_clib).
    extern fn sapp_android_get_native_activity() callconv(.c) ?*const anyopaque;
} else struct {};

// ── Callbacks invoked from the C JNI glue (Looper thread) ───────────────
//
// The C side calls these once per device it discovers / loses. They are
// `export`ed with C linkage so the glue can resolve them by name. They are
// only meaningful on Android, but `export` is harmless elsewhere; we still
// gate the body so non-Android builds don't pull in unused machinery.

/// Push a `.connected` event. `descriptor`/`name` are borrowed for the
/// duration of the call only (copied into the COPY-only event).
export fn labelle_android_on_device_added(
    device_id: i32,
    sources: i32,
    name_ptr: [*]const u8,
    name_len: usize,
    descriptor_ptr: [*]const u8,
    descriptor_len: usize,
) callconv(.c) void {
    if (!is_android) return;
    const name = name_ptr[0..name_len];
    const descriptor = descriptor_ptr[0..descriptor_len];

    var ev = GamepadEvent{ .kind = .connected, .slot = @bitCast(device_id) };
    ev.setName(name);
    ev.guid = descriptorGuid(descriptor);
    ev.source_class = classifySources(sources);
    ring.push(ev);
}

/// Push a `.disconnected` event for a device id.
export fn labelle_android_on_device_removed(device_id: i32) callconv(.c) void {
    if (!is_android) return;
    ring.push(GamepadEvent.disconnected(@bitCast(device_id)));
}

pub const Source = struct {
    /// Register the InputDeviceListener and enumerate existing devices.
    /// No-op (and never references JNI symbols) off Android.
    pub fn init() void {
        // A plain `if (comptime !is_android) return;` would NOT stop the
        // compiler from semantically analyzing the JNI references below on
        // host targets (where `jni` is an empty struct). Wrap the whole
        // platform-specific body in `if (comptime is_android)` so those
        // symbols are only analyzed on Android.
        if (comptime is_android) {
            const activity = jni.sapp_android_get_native_activity();
            if (activity == null) return; // no Activity yet → nothing to bind
            jni.labelle_android_gamepad_init(activity);
        }
    }

    /// Unregister the listener and drop any queued hotplug events so a later
    /// `init` starts from a clean ring (no stale connect/disconnect deltas).
    pub fn deinit() void {
        if (comptime is_android) {
            jni.labelle_android_gamepad_shutdown();
        }
        // Drain regardless of target so the module-level ring never carries
        // events across a deinit/init cycle (harmless no-op on host).
        ring.clear();
    }

    /// Drain queued hotplug events. Returns the count written to `out`.
    /// Always 0 on non-Android targets (and when nothing is queued).
    pub fn pollEvents(out: []GamepadEvent) usize {
        if (comptime !is_android) return 0;
        return ring.drain(out);
    }

    /// Diagnostic enumeration is not separately implemented; hotplug events
    /// carry the same identity, so callers can build a snapshot from them.
    pub fn describe(out: []GamepadDescription) usize {
        _ = out;
        return 0;
    }
};

// ── Unit tests (host-runnable — exercise the pure logic, not JNI) ────────

test "classifySources: gamepad bit wins" {
    try std.testing.expectEqual(source.SourceClass.gamepad, classifySources(SOURCE_GAMEPAD));
    try std.testing.expectEqual(source.SourceClass.gamepad, classifySources(SOURCE_JOYSTICK));
    // gamepad + dpad combined → still a real gamepad
    try std.testing.expectEqual(source.SourceClass.gamepad, classifySources(SOURCE_GAMEPAD | SOURCE_DPAD));
}

test "classifySources: dpad-only is a remote" {
    try std.testing.expectEqual(source.SourceClass.dpad_remote, classifySources(SOURCE_DPAD));
}

test "classifySources: keyboard/unknown → unknown" {
    try std.testing.expectEqual(source.SourceClass.unknown, classifySources(0x00000101)); // SOURCE_KEYBOARD
    try std.testing.expectEqual(source.SourceClass.unknown, classifySources(0));
}

test "descriptorGuid is stable and distinguishes devices" {
    const a1 = descriptorGuid("aa:bb:cc:dd");
    const a2 = descriptorGuid("aa:bb:cc:dd");
    const b = descriptorGuid("ee:ff:00:11");
    try std.testing.expectEqual(a1, a2); // deterministic
    try std.testing.expect(!std.mem.eql(u8, &a1, &b)); // distinct inputs differ
}

test "EventRing drains FIFO" {
    var r = EventRing{};
    r.push(GamepadEvent.connected(1, "one"));
    r.push(GamepadEvent.connected(2, "two"));
    r.push(GamepadEvent.disconnected(1));

    var out: [8]GamepadEvent = undefined;
    const n = r.drain(&out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u32, 1), out[0].slot);
    try std.testing.expectEqualStrings("one", out[0].nameSlice());
    try std.testing.expectEqual(@as(u32, 2), out[1].slot);
    try std.testing.expectEqual(GamepadEvent.Kind.disconnected, out[2].kind);
    // fully drained
    try std.testing.expectEqual(@as(usize, 0), r.drain(&out));
}

test "EventRing overflow drops oldest" {
    var r = EventRing{};
    var i: u32 = 0;
    while (i < RING_CAPACITY + 5) : (i += 1) {
        r.push(GamepadEvent.connected(i, "x"));
    }
    var out: [RING_CAPACITY]GamepadEvent = undefined;
    const n = r.drain(&out);
    try std.testing.expectEqual(@as(usize, RING_CAPACITY), n);
    // Oldest 5 (slots 0..4) were dropped; first surviving slot is 5.
    try std.testing.expectEqual(@as(u32, 5), out[0].slot);
}

test "pollEvents returns 0 on host (no Android activity)" {
    var buf: [8]GamepadEvent = undefined;
    try std.testing.expectEqual(@as(usize, 0), Source.pollEvents(&buf));
}
