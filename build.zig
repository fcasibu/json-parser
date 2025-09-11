const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const json_mod = b.addModule("json", .{ .root_source_file = b.path("src/json.zig"), .target = target, .optimize = optimize });
    json_mod.addIncludePath(b.path("src/lib"));
    const lib = b.addLibrary(.{
        .name = "json",
        .linkage = .static,
        .root_module = json_mod,
    });

    lib.addCSourceFile(.{
        .file = b.path("src/lib/stb_wrap.c"),
    });

    lib.linkLibC();
    b.installArtifact(lib);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_exe = b.addTest(.{
        .root_module = test_mod,
    });

    test_mod.addImport("json", json_mod);
    test_exe.linkLibrary(lib);

    const run_tests = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run package tests");
    test_step.dependOn(&run_tests.step);
}
