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

    // --- Linux evdev/udev detection probe (core#33 harness) ---
    //
    // A tiny executable around `gamepad_source` used by
    // `tools/run_detection_check.sh` to runtime-verify the Linux detection
    // source against uinput-created virtual pads (works on WSL2 too — see the
    // probe's module doc). Compiles to a no-op loop on non-Linux hosts via the
    // dispatcher's fallback, so the install step is unconditional.
    const probe = b.addExecutable(.{
        .name = "evdev-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/evdev_probe_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // libc so std.DynLib resolves libudev through real dlopen — without it
    // Zig falls back to its minimal ELF loader, which can't load libudev.
    // Real game binaries link libc anyway, so this matches the consumers.
    probe.root_module.link_libc = true;
    b.installArtifact(probe);
}
