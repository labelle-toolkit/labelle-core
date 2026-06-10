//! Linux gamepad **detection** source (sokol/native, headless/server).
//!
//! Detection/identity only — this file answers "what controllers are plugged
//! in, and when do they appear/disappear?". Reading axes/buttons (semantic
//! state) is out of scope (that lands in #250); here we only open each evdev
//! node far enough to read its identity (`EVIOCGID`, `EVIOCGNAME`, the device
//! capability bits) and then close it.
//!
//! ## How it works
//!
//! * **libudev** is the system of record for hotplug. At `init()` we create a
//!   udev context, enumerate the existing `input` subsystem, and arm a
//!   `udev_monitor` filtered to `input`. `pollEvents` then non-blockingly
//!   drains the monitor: `add`/`remove` udev actions become
//!   `GamepadEvent{ .connected, .disconnected }`.
//! * **Node de-duplication.** A single physical pad shows up as *both* a
//!   legacy `js*` joydev node and one or more `event*` evdev nodes. We only
//!   ever track `event*` nodes (evdev is the modern API and the one #250 will
//!   read state from), and within those we keep just the first event node of a
//!   given device (udev's `ID_INPUT_JOYSTICK` + the kernel `input%d` parent
//!   group them). `js*` nodes are dropped outright.
//! * **Gamepad filtering.** Only nodes whose udev properties mark them as a
//!   joystick/gamepad (`ID_INPUT_JOYSTICK=1`) are surfaced. Keyboards, mice,
//!   touchpads, power-button "devices", etc. are ignored. `source_class` is
//!   always `.gamepad` for what we emit (d-pad-remote classification is a TV
//!   concern handled by the Android/tvOS sources).
//! * **Stable GUID.** Derived from the evdev `input_id` (bustype, vendor,
//!   product, version) laid out in the same 16-byte little-endian shape SDL
//!   uses, so a controller keeps the same `guid` across reconnects and across
//!   the SDL backend. When vendor+product are all-zero (virtual devices) we
//!   fold a hash of the `phys` topology string into the trailing bytes so two
//!   otherwise-identical virtual pads stay distinguishable.
//! * **Permissions.** Opening `/dev/input/event*` requires the caller to be in
//!   the `input` group or for a `uaccess`/udev rule to have tagged the node for
//!   the logged-in seat. When `open` returns `EACCES` we still *detect* the
//!   device (udev tells us it exists and its identity from properties), but we
//!   record it so `describe()` reports `unavailable_reason == .permission_denied`
//!   and we log a one-time hint pointing at the input group / udev rule.
//!
//! On-Linux runtime behavior cannot be exercised on the macOS dev host; the
//! file is written to cross-compile for `*-linux` and is covered by a real
//! Linux box checklist item in the PR. The non-Linux fallback below keeps the
//! module compiling (and contract-conformant) on every other target.
//!
//! TODO(assembler#249): verify on a real Linux box (see PR checklist).

const builtin = @import("builtin");
const std = @import("std");

const source = @import("root.zig");
const GamepadEvent = source.GamepadEvent;
const GamepadDescription = source.GamepadDescription;
const gamepad = @import("../gamepad.zig");

// Everything real is gated behind a comptime check so the file still
// satisfies the `Source.pollEvents` contract (and returns 0) when AstGen
// force-references it under a non-Linux host (see gamepad_source/root.zig's
// "every platform file compiles" test).
const is_linux = builtin.target.os.tag == .linux;

pub const Source = if (is_linux) LinuxSource else FallbackSource;

/// Non-Linux stand-in so the file type-checks on every host. Never selected
/// by the comptime dispatcher in `root.zig` (that only routes `.linux` here),
/// but the contract test in `root.zig` force-references this file on the host.
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

// ── libudev / evdev FFI ────────────────────────────────────────────────
// Minimal hand-written bindings. We avoid `@cImport` so the file parses and
// cross-compiles without libudev headers present on the (macOS) build host;
// the symbols are only *referenced* from code reachable on a linux target,
// and the assembler links `-ludev` for the sokol linux build.

const c = if (is_linux) struct {
    pub const udev = opaque {};
    pub const udev_enumerate = opaque {};
    pub const udev_list_entry = opaque {};
    pub const udev_device = opaque {};
    pub const udev_monitor = opaque {};

    pub extern "udev" fn udev_new() ?*udev;
    pub extern "udev" fn udev_unref(*udev) ?*udev;

    pub extern "udev" fn udev_enumerate_new(*udev) ?*udev_enumerate;
    pub extern "udev" fn udev_enumerate_add_match_subsystem(*udev_enumerate, [*:0]const u8) c_int;
    pub extern "udev" fn udev_enumerate_scan_devices(*udev_enumerate) c_int;
    pub extern "udev" fn udev_enumerate_get_list_entry(*udev_enumerate) ?*udev_list_entry;
    pub extern "udev" fn udev_enumerate_unref(*udev_enumerate) ?*udev_enumerate;

    pub extern "udev" fn udev_list_entry_get_next(*udev_list_entry) ?*udev_list_entry;
    pub extern "udev" fn udev_list_entry_get_name(*udev_list_entry) ?[*:0]const u8;

    pub extern "udev" fn udev_device_new_from_syspath(*udev, [*:0]const u8) ?*udev_device;
    pub extern "udev" fn udev_device_get_devnode(*udev_device) ?[*:0]const u8;
    pub extern "udev" fn udev_device_get_property_value(*udev_device, [*:0]const u8) ?[*:0]const u8;
    pub extern "udev" fn udev_device_get_action(*udev_device) ?[*:0]const u8;
    pub extern "udev" fn udev_device_get_sysname(*udev_device) ?[*:0]const u8;
    pub extern "udev" fn udev_device_unref(*udev_device) ?*udev_device;

    pub extern "udev" fn udev_monitor_new_from_netlink(*udev, [*:0]const u8) ?*udev_monitor;
    pub extern "udev" fn udev_monitor_filter_add_match_subsystem_devtype(*udev_monitor, [*:0]const u8, ?[*:0]const u8) c_int;
    pub extern "udev" fn udev_monitor_enable_receiving(*udev_monitor) c_int;
    pub extern "udev" fn udev_monitor_get_fd(*udev_monitor) c_int;
    pub extern "udev" fn udev_monitor_receive_device(*udev_monitor) ?*udev_device;
    pub extern "udev" fn udev_monitor_unref(*udev_monitor) ?*udev_monitor;
} else struct {};

/// Linux `struct input_id` (linux/input.h). Returned by `EVIOCGID`.
const input_id = extern struct {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
};

// `_IOR('E', 0x02, struct input_id)` and `_IOC(_IOC_READ, 'E', 0x06, len)`.
// Encoded directly so we don't need the `<sys/ioctl.h>` macros.
const EVIOCGID: u32 = 0x80084502; // _IOR('E', 0x02, struct input_id) — 8 bytes
fn EVIOCGNAME(comptime len: u32) u32 {
    // _IOC(_IOC_READ=2, type='E', nr=0x06, size=len)
    return (2 << 30) | (@as(u32, 'E') << 8) | (0x06 << 0) | (len << 16);
}

// ── Implementation ─────────────────────────────────────────────────────

const RING_CAPACITY = 64;
const MAX_TRACKED = 32;

/// Identity of a tracked device. COPY-only.
const Tracked = struct {
    /// udev `sysname`, e.g. "event7" — our stable per-node key for matching
    /// the `remove` action back to the slot we assigned on `add`.
    sysname: [31:0]u8 = [_:0]u8{0} ** 31,
    sysname_len: u8 = 0,
    slot: u32 = 0,
    guid: [16]u8 = [_]u8{0} ** 16,
    name: [gamepad.NAME_CAPACITY:0]u8 = [_:0]u8{0} ** gamepad.NAME_CAPACITY,
    name_len: u8 = 0,
    unavailable_reason: gamepad.UnavailableReason = .none,
    in_use: bool = false,

    fn sysnameSlice(self: *const Tracked) []const u8 {
        return self.sysname[0..self.sysname_len];
    }
    fn setSysname(self: *Tracked, text: []const u8) void {
        const n = @min(text.len, 31);
        @memcpy(self.sysname[0..n], text[0..n]);
        @memset(self.sysname[n..], 0);
        self.sysname_len = @intCast(n);
    }
};

const LinuxSource = struct {
    var udev_ctx: ?*c.udev = null;
    var monitor: ?*c.udev_monitor = null;
    var monitor_fd: c_int = -1;

    // Fixed-size SPSC-ish ring (std.BoundedArray was removed in Zig 0.16).
    var ring: [RING_CAPACITY]GamepadEvent = undefined;
    var ring_head: usize = 0; // next read
    var ring_tail: usize = 0; // next write
    var ring_count: usize = 0;

    var tracked: [MAX_TRACKED]Tracked = [_]Tracked{.{}} ** MAX_TRACKED;
    var next_slot: u32 = 0;

    var initialized: bool = false;
    var perm_hint_logged: bool = false;

    pub fn init() void {
        if (initialized) return;
        initialized = true;

        const ctx = c.udev_new() orelse {
            std.log.scoped(.gamepad).warn("udev_new() failed; Linux gamepad hotplug disabled", .{});
            return;
        };
        udev_ctx = ctx;

        armMonitor(ctx);
        enumerateExisting(ctx);
    }

    pub fn deinit() void {
        if (monitor) |m| {
            _ = c.udev_monitor_unref(m);
            monitor = null;
            monitor_fd = -1;
        }
        if (udev_ctx) |ctx| {
            _ = c.udev_unref(ctx);
            udev_ctx = null;
        }
        ring_head = 0;
        ring_tail = 0;
        ring_count = 0;
        for (&tracked) |*t| t.* = .{};
        next_slot = 0;
        initialized = false;
    }

    /// Drain pending hotplug events. Pulls fresh udev monitor events into the
    /// ring, then copies up to `out.len` of them out.
    pub fn pollEvents(out: []GamepadEvent) usize {
        if (!initialized) init();
        pumpMonitor();

        var written: usize = 0;
        while (written < out.len and ring_count > 0) : (written += 1) {
            out[written] = ring[ring_head];
            ring_head = (ring_head + 1) % RING_CAPACITY;
            ring_count -= 1;
        }
        return written;
    }

    /// Diagnostic snapshot of currently-tracked devices, including ones that
    /// were detected but couldn't be opened (permission_denied).
    pub fn describe(out: []GamepadDescription) usize {
        if (!initialized) init();
        pumpMonitor();

        var n: usize = 0;
        for (&tracked) |*t| {
            if (n >= out.len) break;
            if (!t.in_use) continue;
            var d = GamepadDescription{
                .slot = t.slot,
                .connected = true,
                .guid = t.guid,
                .source_class = .gamepad,
                .type_hint = .unknown,
                .unavailable_reason = t.unavailable_reason,
            };
            d.setName(t.name[0..t.name_len]);
            out[n] = d;
            n += 1;
        }
        return n;
    }

    // ── internals ──────────────────────────────────────────────────────

    fn armMonitor(ctx: *c.udev) void {
        const m = c.udev_monitor_new_from_netlink(ctx, "udev") orelse return;
        _ = c.udev_monitor_filter_add_match_subsystem_devtype(m, "input", null);
        if (c.udev_monitor_enable_receiving(m) < 0) {
            _ = c.udev_monitor_unref(m);
            return;
        }
        monitor = m;
        monitor_fd = c.udev_monitor_get_fd(m);
    }

    fn enumerateExisting(ctx: *c.udev) void {
        const en = c.udev_enumerate_new(ctx) orelse return;
        defer _ = c.udev_enumerate_unref(en);
        _ = c.udev_enumerate_add_match_subsystem(en, "input");
        if (c.udev_enumerate_scan_devices(en) < 0) return;

        var entry = c.udev_enumerate_get_list_entry(en);
        while (entry) |e| : (entry = c.udev_list_entry_get_next(e)) {
            const syspath = c.udev_list_entry_get_name(e) orelse continue;
            const dev = c.udev_device_new_from_syspath(ctx, syspath) orelse continue;
            defer _ = c.udev_device_unref(dev);
            handleDevice(dev, .connected);
        }
    }

    /// Non-blocking drain of the udev monitor fd. We `poll()` with a 0 timeout
    /// so this never stalls the frame.
    fn pumpMonitor() void {
        const m = monitor orelse return;
        if (monitor_fd < 0) return;

        while (true) {
            var pfd = [_]std.posix.pollfd{.{
                .fd = monitor_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&pfd, 0) catch return;
            if (ready == 0) return; // nothing pending
            if (pfd[0].revents & std.posix.POLL.IN == 0) return;

            const dev = c.udev_monitor_receive_device(m) orelse return;
            defer _ = c.udev_device_unref(dev);

            const action_c = c.udev_device_get_action(dev) orelse continue;
            const action = std.mem.span(action_c);
            if (std.mem.eql(u8, action, "add")) {
                handleDevice(dev, .connected);
            } else if (std.mem.eql(u8, action, "remove")) {
                handleDevice(dev, .disconnected);
            }
            // "change"/"bind"/etc. carry no connect/disconnect semantics here.
        }
    }

    /// Classify a udev device and, if it's a gamepad event node, push the
    /// matching connect/disconnect event + update the tracked table.
    fn handleDevice(dev: *c.udev_device, kind: GamepadEvent.Kind) void {
        const sysname_c = c.udev_device_get_sysname(dev) orelse return;
        const sysname = std.mem.span(sysname_c);

        // Only ever track evdev `event*` nodes; drop the duplicate legacy
        // `js*` joydev nodes for the same physical device.
        if (!std.mem.startsWith(u8, sysname, "event")) return;

        // Gamepad filter: udev marks joysticks/gamepads with ID_INPUT_JOYSTICK=1.
        if (!hasProp(dev, "ID_INPUT_JOYSTICK", "1")) return;

        switch (kind) {
            .connected => onConnect(dev, sysname),
            .disconnected => onDisconnect(sysname),
        }
    }

    fn onConnect(dev: *c.udev_device, sysname: []const u8) void {
        // Already tracked? (re-enumerate or duplicate add) — ignore.
        if (findBySysname(sysname) != null) return;

        const slot_idx = allocSlot() orelse {
            std.log.scoped(.gamepad).warn("gamepad track table full ({d}); ignoring {s}", .{ MAX_TRACKED, sysname });
            return;
        };
        const t = &tracked[slot_idx];
        t.* = .{};
        t.in_use = true;
        t.setSysname(sysname);
        t.slot = next_slot;
        next_slot +%= 1;

        // Identity: try to open the node for EVIOCGID/EVIOCGNAME. On EACCES we
        // fall back to udev properties (which don't need an open fd) and mark
        // the device permission_denied so describe() can report it.
        const devnode = c.udev_device_get_devnode(dev);
        var id: input_id = .{ .bustype = 0, .vendor = 0, .product = 0, .version = 0 };
        var name_buf: [gamepad.NAME_CAPACITY]u8 = undefined;
        var name: []const u8 = "";

        var opened = false;
        if (devnode) |dn| {
            const path = std.mem.span(dn);
            if (std.posix.openatZ(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0)) |fd| {
                defer _ = std.os.linux.close(fd);
                opened = true;
                readId(fd, &id);
                name = readName(fd, &name_buf);
            } else |err| switch (err) {
                error.AccessDenied => {
                    t.unavailable_reason = .permission_denied;
                    logPermissionHintOnce(path);
                },
                else => {
                    t.unavailable_reason = .init_failed;
                },
            }
        }

        // Fall back to udev properties for id/name when we couldn't open.
        if (!opened) fillFromProperties(dev, &id, &name_buf, &name);

        t.guid = makeGuid(id, devPhys(dev));
        const n = @min(name.len, gamepad.NAME_CAPACITY);
        @memcpy(t.name[0..n], name[0..n]);
        @memset(t.name[n..], 0);
        t.name_len = @intCast(n);

        var ev = GamepadEvent{
            .kind = .connected,
            .slot = t.slot,
            .guid = t.guid,
            .source_class = .gamepad,
            .type_hint = typeHintFor(id),
        };
        ev.setName(t.name[0..t.name_len]);
        pushEvent(ev);
    }

    fn onDisconnect(sysname: []const u8) void {
        const idx = findBySysname(sysname) orelse return;
        const t = &tracked[idx];
        var ev = GamepadEvent{
            .kind = .disconnected,
            .slot = t.slot,
            .guid = t.guid,
            .source_class = .gamepad,
        };
        ev.setName(t.name[0..t.name_len]);
        pushEvent(ev);
        t.* = .{}; // free the slot
    }

    fn readId(fd: std.posix.fd_t, out: *input_id) void {
        const rc = std.os.linux.ioctl(fd, EVIOCGID, @intFromPtr(out));
        if (std.os.linux.errno(rc) != .SUCCESS) out.* = .{ .bustype = 0, .vendor = 0, .product = 0, .version = 0 };
    }

    fn readName(fd: std.posix.fd_t, buf: *[gamepad.NAME_CAPACITY]u8) []const u8 {
        const rc = std.os.linux.ioctl(fd, EVIOCGNAME(gamepad.NAME_CAPACITY), @intFromPtr(buf));
        // EVIOCGNAME returns the byte length (incl. NUL) on success, <0 on error.
        const signed: isize = @bitCast(rc);
        if (signed <= 0) return "";
        var len: usize = @intCast(signed);
        if (len > gamepad.NAME_CAPACITY) len = gamepad.NAME_CAPACITY;
        // Trim a trailing NUL the kernel includes in the count.
        if (len > 0 and buf[len - 1] == 0) len -= 1;
        return buf[0..len];
    }

    fn fillFromProperties(dev: *c.udev_device, id: *input_id, buf: *[gamepad.NAME_CAPACITY]u8, name: *[]const u8) void {
        // ID_VENDOR_ID / ID_MODEL_ID are 4-digit hex strings when present.
        if (getProp(dev, "ID_VENDOR_ID")) |v| id.vendor = parseHex16(v);
        if (getProp(dev, "ID_MODEL_ID")) |v| id.product = parseHex16(v);
        if (getProp(dev, "ID_BUS")) |v| id.bustype = busTypeFromString(v);
        if (getProp(dev, "ID_MODEL")) |v| {
            const n = @min(v.len, gamepad.NAME_CAPACITY);
            @memcpy(buf[0..n], v[0..n]);
            name.* = buf[0..n];
        }
    }

    fn devPhys(dev: *c.udev_device) []const u8 {
        return getProp(dev, "ID_PATH") orelse "";
    }

    // ── udev property helpers ─────────────────────────────────────────

    fn getProp(dev: *c.udev_device, key: [*:0]const u8) ?[]const u8 {
        const v = c.udev_device_get_property_value(dev, key) orelse return null;
        return std.mem.span(v);
    }

    fn hasProp(dev: *c.udev_device, key: [*:0]const u8, expect: []const u8) bool {
        const v = getProp(dev, key) orelse return false;
        return std.mem.eql(u8, v, expect);
    }

    // ── tracked-table helpers ─────────────────────────────────────────

    fn findBySysname(sysname: []const u8) ?usize {
        for (&tracked, 0..) |*t, i| {
            if (t.in_use and std.mem.eql(u8, t.sysnameSlice(), sysname)) return i;
        }
        return null;
    }

    fn allocSlot() ?usize {
        for (&tracked, 0..) |*t, i| {
            if (!t.in_use) return i;
        }
        return null;
    }

    fn pushEvent(ev: GamepadEvent) void {
        if (ring_count == RING_CAPACITY) {
            // Drop the oldest to make room — hotplug deltas are rare enough
            // that this only bites a caller that never drains.
            ring_head = (ring_head + 1) % RING_CAPACITY;
            ring_count -= 1;
        }
        ring[ring_tail] = ev;
        ring_tail = (ring_tail + 1) % RING_CAPACITY;
        ring_count += 1;
    }

    fn logPermissionHintOnce(path: []const u8) void {
        if (perm_hint_logged) return;
        perm_hint_logged = true;
        std.log.scoped(.gamepad).warn(
            "permission denied opening {s}: add your user to the 'input' group " ++
                "or install a udev rule (e.g. 99-labelle-gamepads.rules with uaccess). " ++
                "Device is detected but cannot be read.",
            .{path},
        );
    }
};

// ── GUID + type-hint derivation (pure, host-testable) ──────────────────

/// Build the 16-byte SDL-compatible GUID layout from an `input_id`.
/// Layout (little-endian u16s): bustype, 0, vendor, 0, product, 0, version, 0.
/// When vendor and product are both zero (e.g. virtual/uinput devices), fold a
/// FNV-1a hash of `phys` into the trailing 8 bytes so distinct virtual pads
/// don't collide on an all-zero GUID.
fn makeGuid(id: input_id, phys: []const u8) [16]u8 {
    var guid: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u16, guid[0..2], id.bustype, .little);
    std.mem.writeInt(u16, guid[4..6], id.vendor, .little);
    std.mem.writeInt(u16, guid[8..10], id.product, .little);
    std.mem.writeInt(u16, guid[12..14], id.version, .little);

    if (id.vendor == 0 and id.product == 0 and phys.len != 0) {
        const h = std.hash.Fnv1a_64.hash(phys);
        std.mem.writeInt(u64, guid[8..16], h, .little);
        // Re-stamp bustype so the discriminator still leads with bus.
        std.mem.writeInt(u16, guid[0..2], id.bustype, .little);
    }
    return guid;
}

/// Best-guess vendor family from the USB/BT vendor id for glyph selection.
fn typeHintFor(id: input_id) gamepad.TypeHint {
    return switch (id.vendor) {
        0x045e => .xbox, // Microsoft
        0x054c => .playstation, // Sony
        0x057e => .nintendo, // Nintendo
        0 => .unknown,
        else => .generic,
    };
}

fn parseHex16(s: []const u8) u16 {
    return std.fmt.parseInt(u16, s, 16) catch 0;
}

fn busTypeFromString(s: []const u8) u16 {
    // linux/input.h BUS_* constants for the common transports udev reports.
    if (std.mem.eql(u8, s, "usb")) return 0x03; // BUS_USB
    if (std.mem.eql(u8, s, "bluetooth")) return 0x05; // BUS_BLUETOOTH
    return 0;
}

// ── Pure-logic tests (run on any host via `zig build test`) ────────────

test "makeGuid encodes input_id in SDL little-endian layout" {
    const id = input_id{ .bustype = 0x03, .vendor = 0x045e, .product = 0x028e, .version = 0x0110 };
    const g = makeGuid(id, "");
    try std.testing.expectEqual(@as(u16, 0x03), std.mem.readInt(u16, g[0..2], .little));
    try std.testing.expectEqual(@as(u16, 0x045e), std.mem.readInt(u16, g[4..6], .little));
    try std.testing.expectEqual(@as(u16, 0x028e), std.mem.readInt(u16, g[8..10], .little));
    try std.testing.expectEqual(@as(u16, 0x0110), std.mem.readInt(u16, g[12..14], .little));
}

test "makeGuid is stable for the same identity (reconnect key)" {
    const id = input_id{ .bustype = 0x03, .vendor = 0x045e, .product = 0x028e, .version = 0x0110 };
    try std.testing.expectEqual(makeGuid(id, "usb-0000:00:14.0-1"), makeGuid(id, "usb-0000:00:14.0-1"));
}

test "makeGuid distinguishes virtual devices by phys when vid/pid are zero" {
    const id = input_id{ .bustype = 0x06, .vendor = 0, .product = 0, .version = 0 };
    const a = makeGuid(id, "virtual/0");
    const b = makeGuid(id, "virtual/1");
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "typeHintFor maps known vendors" {
    try std.testing.expectEqual(gamepad.TypeHint.xbox, typeHintFor(.{ .bustype = 3, .vendor = 0x045e, .product = 0, .version = 0 }));
    try std.testing.expectEqual(gamepad.TypeHint.playstation, typeHintFor(.{ .bustype = 3, .vendor = 0x054c, .product = 0, .version = 0 }));
    try std.testing.expectEqual(gamepad.TypeHint.nintendo, typeHintFor(.{ .bustype = 3, .vendor = 0x057e, .product = 0, .version = 0 }));
    try std.testing.expectEqual(gamepad.TypeHint.generic, typeHintFor(.{ .bustype = 3, .vendor = 0x1234, .product = 0, .version = 0 }));
    try std.testing.expectEqual(gamepad.TypeHint.unknown, typeHintFor(.{ .bustype = 0, .vendor = 0, .product = 0, .version = 0 }));
}

test "busTypeFromString maps udev ID_BUS strings" {
    try std.testing.expectEqual(@as(u16, 0x03), busTypeFromString("usb"));
    try std.testing.expectEqual(@as(u16, 0x05), busTypeFromString("bluetooth"));
    try std.testing.expectEqual(@as(u16, 0), busTypeFromString("i2c"));
}
