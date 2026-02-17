const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zig-ecs dependency
    const zig_ecs_dep = b.dependency("zig_ecs", .{ .target = target, .optimize = optimize });
    const zig_ecs_module = zig_ecs_dep.module("zig-ecs");

    // Core module
    const core_module = b.addModule("labelle-core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_module.addImport("zig_ecs", zig_ecs_module);

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_ecs", .module = zig_ecs_module },
            },
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run labelle-core tests");
    test_step.dependOn(&run_tests.step);
}
