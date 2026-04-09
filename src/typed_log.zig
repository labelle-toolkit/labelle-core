//! Typed structured-decision log — a fixed-cap inline buffer of `LogEntry`
//! values that systems use to record *what they did and why*, for later
//! inspection by tests, the caretaker, or developer tooling.
//!
//! This is a different concept from `log.zig`. `log.zig` is a *log sink
//! interface* — how a formatted message gets emitted to stderr/stub at the
//! point of call. `typed_log.zig` is a *structured decision record* — the
//! receiving end keeps the entries around and tests assert against them.
//!
//! Designed and validated across the four PoCs in the
//! `rfc/manager-complexity` validation plan (`poc-caretaker`,
//! `poc-fsm-controller`, `poc-job-toil`, `poc-command-buffer`). Each
//! reinvented the same shape; this is the consolidated single type.
//!
//! Design constraints (see RFC F3 for the rationale):
//!   - **No allocator.** Fixed-cap inline buffer chosen at comptime.
//!     Debug-only / scoped use cases; if a single tick produces more
//!     entries than the cap, the right answer is to stop the sim, not
//!     to grow the buffer.
//!   - **No error union on `add`.** A user pushing a record never has
//!     to write `try` or `catch unreachable`. Overflow is silent;
//!     `bufPrint` failure truncates rather than failing.
//!   - **`rule` is `[]const u8` and not stored in the buffer** — callers
//!     pass string literals so the slice points into rodata. The log
//!     never owns the string memory.

const std = @import("std");

pub const MAX_MSG_LEN = 160;

pub const LogEntry = struct {
    /// Category / source name. Caller-owned (typically a string literal).
    rule: []const u8,
    /// Optional tick number, set by the scheduler that owns the log.
    /// Defaults to 0 — callers that don't care about ticks ignore it.
    tick: u64 = 0,
    msg_buf: [MAX_MSG_LEN]u8 = undefined,
    msg_len: usize = 0,

    pub fn message(self: *const LogEntry) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }
};

/// Fixed-cap typed log. CAP entries inline, zero allocations, no error
/// path on `add`.
///
/// Usage:
///
///     var log = labelle_core.TypedLog(32){};
///     log.add("conflict", "worker {d} ...", .{worker_id});
///     for (log.slice()) |entry| { ... }
///     log.reset();
pub fn TypedLog(comptime CAP: usize) type {
    return struct {
        const Self = @This();

        count: usize = 0,
        current_tick: u64 = 0,
        entries: [CAP]LogEntry = undefined,

        /// Discard all entries. Cheap — just resets the count.
        pub fn reset(self: *Self) void {
            self.count = 0;
        }

        /// Set the tick number that subsequent `add` calls record against.
        /// Optional — only used by callers that care about per-tick grouping.
        pub fn setTick(self: *Self, tick: u64) void {
            self.current_tick = tick;
        }

        /// Append an entry. Silently no-ops if the buffer is full.
        ///
        /// If the formatted message exceeds `MAX_MSG_LEN`, the entry's
        /// message is truncated to a valid prefix of what would have
        /// been written. We use `std.Io.Writer.fixed` (rather than
        /// `std.fmt.bufPrint`) so the truncation case never exposes
        /// uninitialized buffer bytes — `Writer.fixed`'s drain handler
        /// fills the buffer as much as possible before returning
        /// `error.WriteFailed`, so `w.end` always points at a valid
        /// prefix. (`bufPrint` makes no such guarantee on
        /// `error.NoSpaceLeft`, which is undefined behavior territory
        /// for the bytes we'd otherwise have to read.)
        pub fn add(
            self: *Self,
            rule: []const u8,
            comptime fmt: []const u8,
            args: anytype,
        ) void {
            if (self.count >= CAP) return;
            const e = &self.entries[self.count];
            e.rule = rule;
            e.tick = self.current_tick;
            var w = std.Io.Writer.fixed(&e.msg_buf);
            // print returns error.WriteFailed when the buffer fills;
            // we deliberately swallow it because truncation is the
            // documented behavior for oversize messages.
            w.print(fmt, args) catch {};
            e.msg_len = w.end;
            self.count += 1;
        }

        /// View the recorded entries. The returned slice is invalidated
        /// by the next `add` or `reset` call.
        pub fn slice(self: *const Self) []const LogEntry {
            return self.entries[0..self.count];
        }

        /// True when the log is full (`count >= CAP`). Subsequent
        /// `add` calls silently no-op until `reset` is called.
        pub fn isFull(self: *const Self) bool {
            return self.count >= CAP;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "add records the rule, tick, and formatted message" {
    var log = TypedLog(8){};
    log.setTick(42);
    log.add("conflict", "worker {d} pos collision", .{7});

    try testing.expectEqual(@as(usize, 1), log.count);
    const e = &log.slice()[0];
    try testing.expectEqualStrings("conflict", e.rule);
    try testing.expectEqual(@as(u64, 42), e.tick);
    try testing.expectEqualStrings("worker 7 pos collision", e.message());
}

test "reset zeroes the count without touching capacity" {
    var log = TypedLog(8){};
    log.add("a", "first", .{});
    log.add("b", "second", .{});
    try testing.expectEqual(@as(usize, 2), log.count);

    log.reset();
    try testing.expectEqual(@as(usize, 0), log.count);
    try testing.expect(!log.isFull());

    log.add("c", "after reset", .{});
    try testing.expectEqual(@as(usize, 1), log.count);
    try testing.expectEqualStrings("c", log.slice()[0].rule);
}

test "add silently no-ops past CAP" {
    var log = TypedLog(3){};
    log.add("r", "first", .{});
    log.add("r", "second", .{});
    log.add("r", "third", .{});
    try testing.expect(log.isFull());

    // 4th call: silent no-op, no panic, no error
    log.add("r", "fourth (dropped)", .{});
    try testing.expectEqual(@as(usize, 3), log.count);
    try testing.expectEqualStrings("third", log.slice()[2].message());
}

test "oversize message: truncates to a valid prefix, never garbage" {
    var log = TypedLog(4){};
    // Build a format that produces well over MAX_MSG_LEN bytes of 'x'.
    log.add("oversize", "{s}", .{"x" ** (MAX_MSG_LEN * 2)});

    try testing.expectEqual(@as(usize, 1), log.count);

    const msg = log.slice()[0].message();
    // The truncation point may land anywhere up to MAX_MSG_LEN; what
    // matters is that every byte we read is one we wrote (i.e., 'x').
    // The previous implementation could expose uninitialized bytes
    // here — both Cursor Bugbot and Gemini caught it on labelle-core#9.
    try testing.expect(msg.len <= MAX_MSG_LEN);
    try testing.expect(msg.len > 0);
    for (msg) |c| {
        try testing.expectEqual(@as(u8, 'x'), c);
    }
}

test "moderate-length message: written exactly, no truncation" {
    var log = TypedLog(4){};
    // 50 bytes — well under MAX_MSG_LEN = 160.
    log.add("ok", "{s}", .{"x" ** 50});

    try testing.expectEqual(@as(usize, 1), log.count);
    try testing.expectEqual(@as(usize, 50), log.slice()[0].msg_len);
    for (log.slice()[0].message()) |c| {
        try testing.expectEqual(@as(u8, 'x'), c);
    }
}

test "slice is empty for an untouched log" {
    const log = TypedLog(8){};
    try testing.expectEqual(@as(usize, 0), log.slice().len);
}

test "current_tick persists across multiple add calls" {
    var log = TypedLog(8){};
    log.setTick(100);
    log.add("a", "first", .{});
    log.add("b", "second", .{});
    log.setTick(101);
    log.add("c", "third", .{});

    try testing.expectEqual(@as(u64, 100), log.slice()[0].tick);
    try testing.expectEqual(@as(u64, 100), log.slice()[1].tick);
    try testing.expectEqual(@as(u64, 101), log.slice()[2].tick);
}
