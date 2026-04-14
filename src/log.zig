/// Comptime-validated log sink interface.
/// The assembler provides the concrete Impl (StderrLogSink, StubLogSink, etc.).
/// Engine and plugins use this for zero-cost dispatch.

const builtin = @import("builtin");

pub const LogLevel = enum(u2) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn label(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

/// Default minimum log level based on optimize mode.
/// Debug: all levels. Release: warn + err only.
pub const default_min_level: LogLevel = switch (builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe => .info,
    .ReleaseFast, .ReleaseSmall => .warn,
};

pub fn LogSinkInterface(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "write")) @compileError("LogSink impl must define 'write(level, scope, elapsed_s, comptime fmt, args) void'");
    }

    return struct {
        pub const Implementation = Impl;

        pub inline fn write(
            level: LogLevel,
            comptime scope: []const u8,
            elapsed_s: f64,
            comptime fmt: []const u8,
            args: anytype,
        ) void {
            Impl.write(level, scope, elapsed_s, fmt, args);
        }

        pub inline fn flush() void {
            if (@hasDecl(Impl, "flush")) Impl.flush();
        }
    };
}

/// No-op log sink for testing and headless builds.
pub const StubLogSink = struct {
    pub fn write(
        _: LogLevel,
        comptime _: []const u8,
        _: f64,
        comptime _: []const u8,
        _: anytype,
    ) void {}
};

/// Default stderr log sink — writes to std.debug.print on desktop and to
/// `__android_log_print` on Android (because Android stderr goes nowhere
/// visible; everything ships through logcat).
/// Format: [1.234s] INFO  scope: message
pub const StderrLogSink = struct {
    const std = @import("std");

    const is_android = builtin.target.abi == .android or builtin.target.abi == .androideabi;

    // Android NDK liblog priorities
    const ANDROID_LOG_DEBUG: c_int = 3;
    const ANDROID_LOG_INFO: c_int = 4;
    const ANDROID_LOG_WARN: c_int = 5;
    const ANDROID_LOG_ERROR: c_int = 6;

    extern fn __android_log_write(prio: c_int, tag: [*:0]const u8, msg: [*:0]const u8) c_int;

    fn androidPrio(level: LogLevel) c_int {
        return switch (level) {
            .debug => ANDROID_LOG_DEBUG,
            .info => ANDROID_LOG_INFO,
            .warn => ANDROID_LOG_WARN,
            .err => ANDROID_LOG_ERROR,
        };
    }

    pub fn write(
        level: LogLevel,
        comptime scope: []const u8,
        elapsed_s: f64,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        const prefix = comptime if (scope.len > 0) scope ++ ": " else "";
        if (comptime is_android) {
            // Format into a stack buffer, NUL-terminate, hand off to logcat.
            // 1 KiB matches the NDK's per-message limit before truncation.
            var buf: [1024]u8 = undefined;
            const formatted = std.fmt.bufPrint(
                &buf,
                "[{d:.3}s] " ++ prefix ++ fmt ++ "\x00",
                .{elapsed_s} ++ args,
            ) catch blk: {
                buf[buf.len - 1] = 0;
                break :blk buf[0 .. buf.len - 1 :0];
            };
            const msg_z: [*:0]const u8 = @ptrCast(formatted.ptr);
            _ = __android_log_write(androidPrio(level), "labelle", msg_z);
        } else {
            std.debug.print("[{d:.3}s] {s:<5} " ++ prefix ++ fmt ++ "\n", .{ elapsed_s, level.label() } ++ args);
        }
    }
};
