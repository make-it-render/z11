const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const x11 = b.addModule(
        "x11",
        .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize == .ReleaseSmall,
        },
    );

    {
        const demo_mod = b.addModule(
            "demo",
            .{
                .root_source_file = b.path("src/demo.zig"),
                .target = target,
                .optimize = optimize,
                .strip = optimize == .ReleaseSmall,
                .single_threaded = true,
            },
        );
        demo_mod.addImport("x11", x11);

        const demo_exe = b.addExecutable(.{
            .name = "demo",
            .root_module = demo_mod,
        });

        b.installArtifact(demo_exe);

        const run_cmd = b.addRunArtifact(demo_exe);
        const run_step = b.step("run", "Run demo");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const shm_verify_mod = b.addModule("shm_verify", .{
            .root_source_file = b.path("src/shm_verify.zig"),
            .target = target,
            .optimize = optimize,
        });
        shm_verify_mod.addImport("x11", x11);

        const shm_verify_exe = b.addExecutable(.{
            .name = "shm-verify",
            .root_module = shm_verify_mod,
        });

        const run_cmd = b.addRunArtifact(shm_verify_exe);
        const run_step = b.step("shm-verify", "Verify the MIT-SHM path against a live X server");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const tests_mod = b.addModule("tests", .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });

        const tests = b.addTest(.{
            .root_module = tests_mod,
        });

        const run_tests = b.addRunArtifact(tests);
        const run_tests_step = b.step("test", "Run tests");
        run_tests_step.dependOn(&run_tests.step);
    }

    {
        const docs_mod = b.addModule("docs", .{
            .target = target,
            .optimize = .Debug,
            .root_source_file = b.path("src/root.zig"),
        });

        const docs = b.addObject(.{
            .name = "docs",
            .root_module = docs_mod,
        });

        const install_docs = b.addInstallDirectory(.{
            .source_dir = docs.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        });

        const docs_step = b.step("docs", "Install documentation");
        docs_step.dependOn(&install_docs.step);
    }
}
