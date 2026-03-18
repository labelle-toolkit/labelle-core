/// Comptime-validated log sink interface.
/// The assembler provides the concrete Impl (StderrSink, EmscriptenSink, etc.).
/// Engine and plugins use this for zero-cost dispatch.

pub const LogLevel = enum(u3) {
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
        _: f32,
        comptime _: []const u8,
        _: anytype,
    ) void {}
};

/// Default stderr log sink — writes to std.debug.print.
/// Suitable for desktop builds. Format: [1.234s] INFO  scope: message
pub const StderrLogSink = struct {
    const std = @import("std");

    pub fn write(
        level: LogLevel,
        comptime scope: []const u8,
        elapsed_s: f32,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        const prefix = if (scope.len > 0) scope ++ ": " else "";
        std.debug.print("[{d:.3}s] {s:<5} " ++ prefix ++ fmt ++ "\n", .{elapsed_s, level.label()} ++ args);
    }
};
