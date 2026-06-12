//! core#33 harness — Linux evdev/udev gamepad DETECTION probe.
//!
//! Runs the real `gamepad_source` (on Linux: the libudev/evdev detection
//! source in `gamepad_source/linux.zig`) for ~12 seconds and prints one
//! machine-greppable line per observation:
//!
//!   EVENT kind=connected slot=0 guid=<32 hex> name=Virtual Pad A
//!   EVENT kind=disconnected slot=0 guid=<32 hex> name=Virtual Pad A
//!   DESCRIBE slot=0 guid=<32 hex> name=...
//!
//! Driven by `tools/uinput_feeder.py` and asserted by
//! `tools/run_detection_check.sh`. Works on any Linux with `/dev/uinput`,
//! including stock WSL2 (uinput/evdev ship as kernel modules there) — no
//! physical controller or bare-metal box required for this subset.

const std = @import("std");
const builtin = @import("builtin");
const source = @import("gamepad_source/root.zig");

const RUN_NS: u64 = 12 * std.time.ns_per_s;
const POLL_NS: u64 = 50 * std.time.ns_per_ms;

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
}
