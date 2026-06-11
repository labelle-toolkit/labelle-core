//! Cross-compile platform compile-check entry point (labelle-core#23, epic #609).
//!
//! ## Why this file exists
//!
//! `gamepad_source/root.zig` selects ONE platform file per target at comptime.
//! On the host (macOS/Linux desktop) the selector picks `unsupported.zig`, so
//! `android.zig` / `ios.zig` / `linux.zig` / `wasm.zig` are NEVER compiled by a
//! host `zig build test`. Even `zig test -target aarch64-linux-android` is not
//! enough on its own: Zig's lazy analysis only compiles a function body when it
//! is referenced, and the foreign-platform `Source` namespaces resolve to their
//! real implementation (`GcSource`/`LinuxSource`/`WasmSource`/the JNI android
//! `Source`) only when built for that target — but nothing forces their bodies.
//!
//! This blind spot let two real, target-only breaks merge:
//!   * android.zig's missing `SourceClass` re-export + an `std.Thread.Mutex`
//!     (Zig 0.16 removed it) — caught only by the APK build (#248/#25).
//!   * an ECS adapter 64-bit atomic — caught only by the cli WASM build.
//!
//! ## What this file does
//!
//! It imports the platform file selected for whatever target it is BUILT for and
//! FORCES full semantic analysis of that platform's `Source` via
//! `refAllDeclsRecursive` plus explicit references to the contract surface
//! (`pollEvents` is required; `init`/`deinit`/`describe` are referenced when
//! present). Built with `zig build-obj` for each foreign target by the
//! `check-platforms` build step, this makes platform-only breaks fail the build
//! instead of merging silently.
//!
//! `build-obj` (compile, no link) is sufficient for every front-end error class
//! we care about — missing decls, removed std APIs, illegal atomics, type
//! errors. Android's JNI symbols are `@extern` declarations that compile fine at
//! build-obj stage with no NDK present (the NDK is only needed to *link* an APK).

const std = @import("std");
const builtin = @import("builtin");

// Go through the real selector (`gamepad_source/root.zig`) rather than
// duplicating the comptime dispatch, so building this entry point for
// `-target aarch64-linux-android` analyses android.zig, for `-target
// aarch64-ios` analyses ios.zig, etc. — exactly the file the engine would use.
const source = @import("gamepad_source/root.zig");
const Source = source.Source;

/// Recursively reference every public decl of a container so the semantic
/// analyzer must compile each one. Unlike `std.testing.refAllDecls`, this is
/// NOT gated on `builtin.is_test` (we run under `build-obj`, not `test`) and it
/// descends into nested containers, so the lazily-analysed function bodies in
/// the platform file actually get front-end-checked. The `seen` list breaks
/// recursion on self-referential types.
fn refAllDeclsRecursive(comptime T: type, comptime seen: []const type) void {
    inline for (seen) |s| if (s == T) return;
    const next_seen = seen ++ [_]type{T};
    inline for (comptime std.meta.declarations(T)) |decl| {
        const field = @field(T, decl.name);
        const FieldT = @TypeOf(field);
        // Reference the decl itself (forces analysis of fn bodies / consts).
        _ = &field;
        // Descend into nested struct/union/enum/opaque namespaces.
        if (FieldT == type) {
            switch (@typeInfo(field)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => refAllDeclsRecursive(field, next_seen),
                else => {},
            }
        }
    }
}

comptime {
    // Force full analysis of every decl reachable from the platform's `Source`
    // — this compiles the function bodies that lazy analysis would skip.
    refAllDeclsRecursive(Source, &.{});

    // Belt-and-suspenders explicit references to the contract surface, so the
    // check still bites even if a future `Source` hides a decl (e.g. behind a
    // comptime branch). `pollEvents` is required; the rest are optional.
    _ = &Source.pollEvents;
    if (@hasDecl(Source, "init")) _ = &Source.init;
    if (@hasDecl(Source, "deinit")) _ = &Source.deinit;
    if (@hasDecl(Source, "describe")) _ = &Source.describe;
}

// A real entry point so `build-obj` has something to emit; keeps the analysis
// above from being dead-code-eliminated before the front-end runs.
pub fn main() void {
    var buf: [1]source.GamepadEvent = undefined;
    _ = Source.pollEvents(&buf);
}
