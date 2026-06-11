const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_module = b.addModule("labelle-core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const root_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/root_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-core", .module = core_module },
            },
        }),
    });

    // --- Desktop gamepad source: link windowless SDL2 (core#28) ---
    //
    // `gamepad_source/desktop.zig` is selected for macOS/Windows desktop
    // targets and reads gamepads through SDL2 (joystick/gamecontroller
    // subsystems, no video). Every artifact that COMPILES core for a desktop
    // target must therefore satisfy the SDL2 symbols. All SDL `extern`s are
    // gated behind `comptime is_desktop`, so non-desktop targets pull no SDL.
    //
    // A module (`addModule`) cannot itself link a system library — that is a
    // compile-step concern — so we link SDL on each compiling artifact (the
    // two test artifacts here). Downstream consumers of the `labelle-core`
    // module link SDL on their own desktop artifact via the core-unify path
    // (see core#28; engine/backend build wiring is a follow-up PR).
    if (isDesktopTarget(target)) {
        linkDesktopSdl(b, tests);
        linkDesktopSdl(b, root_tests);
    }

    const run_tests = b.addRunArtifact(tests);
    const run_root_tests = b.addRunArtifact(root_tests);
    const test_step = b.step("test", "Run labelle-core tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_root_tests.step);

    // --- Cross-compile platform compile-checks (labelle-core#23, epic #609) ---
    //
    // The host `test` step only ever compiles the gamepad_source platform file
    // selected for the host (`unsupported.zig`); the per-OS files
    // (android/ios/linux/wasm) are never analysed, so platform-only breaks
    // merge silently (see #25/#248, and the cli WASM atomic regression).
    //
    // For each foreign target we cross-compile `gamepad_source/platform_check.zig`,
    // which `refAllDeclsRecursive`'s that target's `Source` and explicitly
    // references the contract surface — forcing full front-end analysis of the
    // platform file's function bodies. `build-obj` (compile, no link) catches
    // the front-end error classes we miss (missing decls, removed std APIs,
    // illegal atomics, type errors). No NDK/SDK/browser linkage is required:
    // android's JNI symbols are `@extern`s that compile fine at build-obj.
    const platform_targets = [_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android },
        .{ .cpu_arch = .aarch64, .os_tag = .ios },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .wasm32, .os_tag = .freestanding },
    };

    const check_platforms_step = b.step(
        "check-platforms",
        "Cross-compile each gamepad_source per-OS platform file (compile-check)",
    );

    for (platform_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        const abi_tag = if (query.abi) |a| @tagName(a) else "none";
        const obj = b.addObject(.{
            .name = b.fmt("gamepad_source_check_{s}_{s}_{s}", .{
                @tagName(query.cpu_arch.?),
                @tagName(query.os_tag.?),
                abi_tag,
            }),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gamepad_source_platform_check.zig"),
                .target = resolved,
                .optimize = optimize,
            }),
        });
        check_platforms_step.dependOn(&obj.step);
    }

    // Fold the cross-compile checks into the default `test` target so CI (and
    // `zig build test`) can't go green while a per-OS file is broken.
    test_step.dependOn(check_platforms_step);
}

/// True when the resolved target is a desktop OS that currently SELECTS the
/// SDL-backed `gamepad_source/desktop.zig` — i.e. macOS/Windows only. Mirrors
/// the `is_desktop` comptime in that file. Linux is deliberately excluded: it
/// still uses `gamepad_source/linux.zig` (libudev), not the SDL source, so we
/// must NOT link SDL for it (no SDL is present on the Linux CI image; linking
/// it would add an unused dependency and break the build). When Linux migrates
/// from `linux.zig` to the SDL source, add `.linux` here as a noted follow-up.
fn isDesktopTarget(target: std.Build.ResolvedTarget) bool {
    const t = target.result;
    if (t.abi == .android or t.abi == .androideabi) return false;
    if (t.cpu.arch.isWasm()) return false;
    return switch (t.os.tag) {
        .macos, .windows => true,
        else => false,
    };
}

/// Link system SDL2 (joystick/gamecontroller subsystems) into a compile step
/// for desktop targets. On macOS Homebrew the headers/libs live under
/// `/opt/homebrew`; we add that include/lib path so `linkSystemLibrary` finds
/// SDL2 without a pkg-config round-trip. We declare only the handful of SDL
/// `extern`s we use in Zig, so no SDL headers are needed at compile time —
/// the include/lib paths are purely for the linker to resolve `-lSDL2`.
fn linkDesktopSdl(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const mod = compile.root_module;
    mod.link_libc = true;
    // Homebrew prefix on Apple Silicon. Harmless if absent on other hosts;
    // `linkSystemLibrary` also consults the default system search paths.
    if (compile.rootModuleTarget().os.tag == .macos) {
        mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    }
    mod.linkSystemLibrary("SDL2", .{});
    _ = b;
}
