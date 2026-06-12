//! core#33 harness — Linux evdev/udev gamepad detection + STATE probe.
//!
//! Runs the real `gamepad_source` (on Linux: `gamepad_source/linux.zig`)
//! for ~16 seconds, calling `update()` every poll tick like a game frame
//! loop, and prints one machine-greppable line per observation:
//!
//!   EVENT kind=connected slot=0 guid=<32 hex> name=Virtual Pad A
//!   STATE slot=0 btn=7 pressed
//!   STATE slot=0 axis=0 val=1.00
//!   DESCRIBE slot=0 guid=<32 hex> name=...
//!   TIMING update calls=N avg_ns=... max_ns=...
//!
//! STATE button lines are press edges (isButtonPressed); axis lines print
//! when a value moves by more than 0.5 from the last printed value. The
//! TIMING line grounds the per-frame cost discussion with measured numbers.
//!
//! Driven by `tools/uinput_feeder.py` and asserted by
//! `tools/run_detection_check.sh`. Works on any Linux with `/dev/uinput`,
//! including stock WSL2 — no hardware needed for this subset.

const std = @import("std");
const builtin = @import("builtin");
const source = @import("gamepad_source/root.zig");
const platform = @import("gamepad_source/linux.zig");

const RUN_NS: u64 = 16 * std.time.ns_per_s;
const POLL_NS: u64 = 50 * std.time.ns_per_ms;
const MAX_SLOTS: u32 = 8;
const BUTTON_COUNT: u32 = 18;
const AXIS_COUNT: u32 = 6;

/// Plain nanosleep via the Linux syscall layer — `std.Thread.sleep` /
/// `std.posix.nanosleep` are gone in Zig 0.16 (the `Io` interface owns
/// time) and this probe has no Io. No-op on non-Linux hosts, where the
/// dispatcher routes to the fallback source anyway.
fn sleepPoll() void {
    if (comptime builtin.target.os.tag == .linux) {
        const ts: std.os.linux.timespec = .{ .sec = 0, .nsec = POLL_NS };
        _ = std.os.linux.nanosleep(&ts, null);
    }
}

fn nowNs() u64 {
    if (comptime builtin.target.os.tag == .linux) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
    return 0;
}

fn guidHex(guid: ?[16]u8, buf: *[32]u8) []const u8 {
    const g = guid orelse return "none";
    const hex = "0123456789abcdef";
    for (g, 0..) |b, i| {
        buf[i * 2] = hex[b >> 4];
        buf[i * 2 + 1] = hex[b & 0xf];
    }
    return buf;
}

pub fn main() void {
    source.init();
    defer source.deinit();

    const Src = platform.Source;

    // Last-printed axis values so we only log meaningful movements.
    var last_axes: [MAX_SLOTS][AXIS_COUNT]f32 = [_][AXIS_COUNT]f32{[_]f32{0} ** AXIS_COUNT} ** MAX_SLOTS;

    var update_calls: u64 = 0;
    var update_total_ns: u64 = 0;
    var update_max_ns: u64 = 0;

    var elapsed: u64 = 0;
    while (elapsed < RUN_NS) : (elapsed += POLL_NS) {
        var evs: [16]source.GamepadEvent = undefined;
        const n = source.pollEvents(&evs);
        for (evs[0..n]) |*ev| {
            var hexbuf: [32]u8 = undefined;
            std.debug.print("EVENT kind={s} slot={d} guid={s} name={s}\n", .{
                @tagName(ev.kind), ev.slot, guidHex(ev.guid, &hexbuf), ev.nameSlice(),
            });
        }

        const t0 = nowNs();
        Src.update();
        const dt = nowNs() - t0;
        update_calls += 1;
        update_total_ns += dt;
        if (dt > update_max_ns) update_max_ns = dt;

        var slot: u32 = 0;
        while (slot < MAX_SLOTS) : (slot += 1) {
            if (!Src.isAvailable(slot)) continue;
            var btn: u32 = 1;
            while (btn < BUTTON_COUNT) : (btn += 1) {
                if (Src.isButtonPressed(slot, btn)) {
                    std.debug.print("STATE slot={d} btn={d} pressed\n", .{ slot, btn });
                }
            }
            var axis: u32 = 0;
            while (axis < AXIS_COUNT) : (axis += 1) {
                const v = Src.axisValue(slot, axis);
                if (@abs(v - last_axes[slot][axis]) > 0.5) {
                    std.debug.print("STATE slot={d} axis={d} val={d:.2}\n", .{ slot, axis, v });
                    last_axes[slot][axis] = v;
                }
            }
        }
        sleepPoll();
    }

    // Final snapshot: after the feeder has destroyed every pad this should
    // print nothing — a non-empty list here means slots weren't freed.
    var descs: [16]source.GamepadDescription = undefined;
    const dn = source.describe(&descs);
    for (descs[0..dn]) |*d| {
        var hexbuf: [32]u8 = undefined;
        std.debug.print("DESCRIBE slot={d} guid={s} name={s}\n", .{
            d.slot, guidHex(d.guid, &hexbuf), d.nameSlice(),
        });
    }

    if (update_calls > 0) {
        std.debug.print("TIMING update calls={d} avg_ns={d} max_ns={d}\n", .{
            update_calls, update_total_ns / update_calls, update_max_ns,
        });
    }
}
