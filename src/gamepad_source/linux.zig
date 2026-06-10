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
//!   read state from); `js*` nodes are dropped outright. Within the `event*`
//!   nodes a single physical pad can still expose several joystick-class nodes
//!   (e.g. a motion-control endpoint alongside the buttons endpoint), so we
//!   also de-dup by the device identity GUID: the first usable `event*` node of
//!   a given GUID wins and later ones for the same GUID are dropped.
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
//! libudev is loaded at runtime via `std.DynLib` (dlopen of `libudev.so.1`)
//! rather than link-time `extern "udev"`. A link-time dependency forces every
//! consumer — including the plain `zig build test` artifact, which links no
//! `-ludev` and isn't built `-fPIC` — to satisfy the symbol, and the contract
//! test force-references this file on a native-Linux host. dlopen keeps the
//! module link-clean everywhere while still using libudev when present at
//! runtime; if the library is absent, hotplug is cleanly disabled.
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
// Minimal hand-written bindings, loaded at RUNTIME via `std.DynLib`
// (dlopen) rather than declared as `extern "udev"`. A link-time
// `extern "udev"` forces a hard dynamic-library dependency that the plain
// `zig build test` artifact can't satisfy (no `-ludev`, no `-fPIC`), and the
// contract test in `root.zig` force-references `LinuxSource.init()` on a
// native-Linux host — so the test build failed to link. dlopen keeps this
// file link-clean on every build (test, cross-compile, sokol) while still
// using libudev at runtime when it's present. We avoid `@cImport` so the file
// also parses without libudev headers on the (macOS) build host.

const c = struct {
    pub const udev = opaque {};
    pub const udev_enumerate = opaque {};
    pub const udev_list_entry = opaque {};
    pub const udev_device = opaque {};
    pub const udev_monitor = opaque {};
};

/// Function-pointer table for the libudev symbols we use, populated by
/// `dlopen`+`dlsym` at `init()`. Kept as `?fn` pointers so a missing symbol
/// (or a missing library) cleanly disables the source instead of failing to
/// link. Only referenced from Linux-target code paths.
const Udev = struct {
    handle: std.DynLib,

    udev_new: *const fn () callconv(.c) ?*c.udev,
    udev_unref: *const fn (*c.udev) callconv(.c) ?*c.udev,

    udev_enumerate_new: *const fn (*c.udev) callconv(.c) ?*c.udev_enumerate,
    udev_enumerate_add_match_subsystem: *const fn (*c.udev_enumerate, [*:0]const u8) callconv(.c) c_int,
    udev_enumerate_scan_devices: *const fn (*c.udev_enumerate) callconv(.c) c_int,
    udev_enumerate_get_list_entry: *const fn (*c.udev_enumerate) callconv(.c) ?*c.udev_list_entry,
    udev_enumerate_unref: *const fn (*c.udev_enumerate) callconv(.c) ?*c.udev_enumerate,

    udev_list_entry_get_next: *const fn (*c.udev_list_entry) callconv(.c) ?*c.udev_list_entry,
    udev_list_entry_get_name: *const fn (*c.udev_list_entry) callconv(.c) ?[*:0]const u8,

    udev_device_new_from_syspath: *const fn (*c.udev, [*:0]const u8) callconv(.c) ?*c.udev_device,
    udev_device_get_devnode: *const fn (*c.udev_device) callconv(.c) ?[*:0]const u8,
    udev_device_get_property_value: *const fn (*c.udev_device, [*:0]const u8) callconv(.c) ?[*:0]const u8,
    udev_device_get_action: *const fn (*c.udev_device) callconv(.c) ?[*:0]const u8,
    udev_device_get_sysname: *const fn (*c.udev_device) callconv(.c) ?[*:0]const u8,
    udev_device_unref: *const fn (*c.udev_device) callconv(.c) ?*c.udev_device,

    udev_monitor_new_from_netlink: *const fn (*c.udev, [*:0]const u8) callconv(.c) ?*c.udev_monitor,
    udev_monitor_filter_add_match_subsystem_devtype: *const fn (*c.udev_monitor, [*:0]const u8, ?[*:0]const u8) callconv(.c) c_int,
    udev_monitor_enable_receiving: *const fn (*c.udev_monitor) callconv(.c) c_int,
    udev_monitor_get_fd: *const fn (*c.udev_monitor) callconv(.c) c_int,
    udev_monitor_receive_device: *const fn (*c.udev_monitor) callconv(.c) ?*c.udev_device,
    udev_monitor_unref: *const fn (*c.udev_monitor) callconv(.c) ?*c.udev_monitor,

    /// dlopen libudev and resolve every symbol. Returns null when the library
    /// is absent or any symbol is missing (older/stripped builds).
    fn load() ?Udev {
        // libudev.so.1 is the stable runtime SONAME; the unversioned
        // libudev.so only ships with -dev packages.
        var handle = std.DynLib.open("libudev.so.1") catch
            std.DynLib.open("libudev.so") catch return null;
        errdefer handle.close();

        var u: Udev = undefined;
        u.handle = handle;
        inline for (@typeInfo(Udev).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "handle")) continue;
            @field(u, f.name) = handle.lookup(f.type, f.name) orelse return null;
        }
        return u;
    }
};

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
    /// Runtime-resolved libudev entry points (null when libudev is absent).
    var udev_api: ?Udev = null;
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

        const u = Udev.load() orelse {
            std.log.scoped(.gamepad).warn("libudev not available; Linux gamepad hotplug disabled", .{});
            return;
        };
        udev_api = u;

        const ctx = u.udev_new() orelse {
            std.log.scoped(.gamepad).warn("udev_new() failed; Linux gamepad hotplug disabled", .{});
            udev_api.?.handle.close();
            udev_api = null;
            return;
        };
        udev_ctx = ctx;

        armMonitor(ctx);
        enumerateExisting(ctx);
    }

    pub fn deinit() void {
        if (udev_api) |*u| {
            if (monitor) |m| {
                _ = u.udev_monitor_unref(m);
                monitor = null;
                monitor_fd = -1;
            }
            if (udev_ctx) |ctx| {
                _ = u.udev_unref(ctx);
                udev_ctx = null;
            }
            u.handle.close();
            udev_api = null;
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
        const u = if (udev_api) |*api| api else return;
        const m = u.udev_monitor_new_from_netlink(ctx, "udev") orelse return;
        _ = u.udev_monitor_filter_add_match_subsystem_devtype(m, "input", null);
        if (u.udev_monitor_enable_receiving(m) < 0) {
            _ = u.udev_monitor_unref(m);
            return;
        }
        monitor = m;
        monitor_fd = u.udev_monitor_get_fd(m);
    }

    fn enumerateExisting(ctx: *c.udev) void {
        const u = if (udev_api) |*api| api else return;
        const en = u.udev_enumerate_new(ctx) orelse return;
        defer _ = u.udev_enumerate_unref(en);
        _ = u.udev_enumerate_add_match_subsystem(en, "input");
        if (u.udev_enumerate_scan_devices(en) < 0) return;

        var entry = u.udev_enumerate_get_list_entry(en);
        while (entry) |e| : (entry = u.udev_list_entry_get_next(e)) {
            const syspath = u.udev_list_entry_get_name(e) orelse continue;
            const dev = u.udev_device_new_from_syspath(ctx, syspath) orelse continue;
            defer _ = u.udev_device_unref(dev);
            handleDevice(dev, .connected);
        }
    }

    /// Non-blocking drain of the udev monitor fd. We `poll()` with a 0 timeout
    /// so this never stalls the frame.
    fn pumpMonitor() void {
        const u = if (udev_api) |*api| api else return;
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

            const dev = u.udev_monitor_receive_device(m) orelse return;
            defer _ = u.udev_device_unref(dev);

            const action_c = u.udev_device_get_action(dev) orelse continue;
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
        const u = if (udev_api) |*api| api else return;
        const sysname_c = u.udev_device_get_sysname(dev) orelse return;
        const sysname = std.mem.span(sysname_c);

        // Only ever track evdev `event*` nodes; drop the duplicate legacy
        // `js*` joydev nodes for the same physical device.
        if (!std.mem.startsWith(u8, sysname, "event")) return;

        // Gamepad filter: udev marks joysticks/gamepads with ID_INPUT_JOYSTICK=1.
        if (!hasProp(u, dev, "ID_INPUT_JOYSTICK", "1")) return;

        switch (kind) {
            .connected => onConnect(u, dev, sysname),
            .disconnected => onDisconnect(sysname),
        }
    }

    fn onConnect(u: *const Udev, dev: *c.udev_device, sysname: []const u8) void {
        // Already tracked under this exact node? (re-enumerate / duplicate add)
        if (findBySysname(sysname) != null) return;

        // Resolve identity first so we can de-dup by device GUID below: a single
        // physical pad can expose multiple joystick-class `event*` nodes, and we
        // want exactly one tracked slot per physical device.
        var id: input_id = .{ .bustype = 0, .vendor = 0, .product = 0, .version = 0 };
        var name_buf: [gamepad.NAME_CAPACITY]u8 = undefined;
        var name: []const u8 = "";
        var reason: gamepad.UnavailableReason = .none;

        // Identity: try to open the node for EVIOCGID/EVIOCGNAME. On EACCES we
        // fall back to udev properties (which don't need an open fd) and mark
        // the device permission_denied so describe() can report it. With no
        // devnode at all there's nothing to open and the node is unusable.
        const devnode = u.udev_device_get_devnode(dev);
        if (devnode) |dn| {
            const path = std.mem.span(dn);
            if (std.posix.openatZ(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0)) |fd| {
                // std.posix.close does not exist in Zig 0.16; the evdev fd is a
                // raw Linux fd, so close it through the linux syscall wrapper.
                defer _ = std.os.linux.close(fd);
                readId(fd, &id);
                name = readName(fd, &name_buf);
            } else |err| switch (err) {
                error.AccessDenied => {
                    reason = .permission_denied;
                    logPermissionHintOnce(path);
                },
                else => {
                    reason = .init_failed;
                },
            }
        } else {
            // No `/dev/input/event*` node exists for this device; we can detect
            // it via udev but can never open/read it.
            reason = .not_present;
        }

        // Backfill any identity fields the evdev ioctls didn't supply (open
        // failed entirely, or EVIOCGID/EVIOCGNAME returned empty) from udev
        // properties, which don't require an open fd.
        fillFromProperties(u, dev, &id, &name_buf, &name);

        const guid = makeGuid(id, devPhys(u, dev));

        // De-dup by device identity: if another `event*` node of the same
        // physical pad is already tracked, keep the first and drop this one.
        if (findByGuid(guid) != null) return;

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
        t.unavailable_reason = reason;
        t.guid = guid;

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

    /// Backfill identity fields from udev properties. Only fills a field the
    /// evdev ioctls left at its zero/empty default, so this is safe to call
    /// unconditionally after a (possibly partial) open: it never clobbers a
    /// value the kernel already gave us, but it does rescue the case where the
    /// open succeeded yet `EVIOCGID`/`EVIOCGNAME` returned nothing.
    fn fillFromProperties(u: *const Udev, dev: *c.udev_device, id: *input_id, buf: *[gamepad.NAME_CAPACITY]u8, name: *[]const u8) void {
        // ID_VENDOR_ID / ID_MODEL_ID are 4-digit hex strings when present.
        if (id.vendor == 0) {
            if (getProp(u, dev, "ID_VENDOR_ID")) |v| id.vendor = parseHex16(v);
        }
        if (id.product == 0) {
            if (getProp(u, dev, "ID_MODEL_ID")) |v| id.product = parseHex16(v);
        }
        if (id.bustype == 0) {
            if (getProp(u, dev, "ID_BUS")) |v| id.bustype = busTypeFromString(v);
        }
        if (name.len == 0) {
            if (getProp(u, dev, "ID_MODEL")) |v| {
                const n = @min(v.len, gamepad.NAME_CAPACITY);
                @memcpy(buf[0..n], v[0..n]);
                name.* = buf[0..n];
            }
        }
    }

    fn devPhys(u: *const Udev, dev: *c.udev_device) []const u8 {
        return getProp(u, dev, "ID_PATH") orelse "";
    }

    // ── udev property helpers ─────────────────────────────────────────

    fn getProp(u: *const Udev, dev: *c.udev_device, key: [*:0]const u8) ?[]const u8 {
        const v = u.udev_device_get_property_value(dev, key) orelse return null;
        return std.mem.span(v);
    }

    fn hasProp(u: *const Udev, dev: *c.udev_device, key: [*:0]const u8, expect: []const u8) bool {
        const v = getProp(u, dev, key) orelse return false;
        return std.mem.eql(u8, v, expect);
    }

    // ── tracked-table helpers ─────────────────────────────────────────

    fn findBySysname(sysname: []const u8) ?usize {
        for (&tracked, 0..) |*t, i| {
            if (t.in_use and std.mem.eql(u8, t.sysnameSlice(), sysname)) return i;
        }
        return null;
    }

    /// Find a tracked slot whose device-identity GUID matches. Used to drop
    /// the second/third `event*` node a single physical pad can expose so we
    /// keep exactly one slot per device. An all-zero GUID is treated as
    /// "no identity" and never matches (so distinct unidentifiable pads with
    /// no devnode and no udev ids aren't collapsed into one).
    fn findByGuid(guid: [16]u8) ?usize {
        const zero = [_]u8{0} ** 16;
        if (std.mem.eql(u8, &guid, &zero)) return null;
        for (&tracked, 0..) |*t, i| {
            if (t.in_use and std.mem.eql(u8, &t.guid, &guid)) return i;
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

test "findByGuid dedupes multiple event nodes of one physical pad" {
    for (&LinuxSource.tracked) |*t| t.* = .{};
    defer {
        for (&LinuxSource.tracked) |*t| t.* = .{};
    }

    const guid = makeGuid(.{ .bustype = 3, .vendor = 0x045e, .product = 0x028e, .version = 0x0110 }, "");
    LinuxSource.tracked[0] = .{ .in_use = true, .slot = 0, .guid = guid };

    // A second event* node with the same identity must collide on GUID...
    try std.testing.expect(LinuxSource.findByGuid(guid) != null);
    // ...but an all-zero GUID is treated as "no identity" and never matches,
    // so unidentifiable pads aren't collapsed into one slot.
    try std.testing.expectEqual(@as(?usize, null), LinuxSource.findByGuid([_]u8{0} ** 16));
}
