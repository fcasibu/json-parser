const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "json",
        .root_source_file = b.path("src/json.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib.addCSourceFile(.{
        .file = b.path("src/lib/stb_wrap.c"),
    });

    lib.linkLibC();
    b.installArtifact(lib);

    const json_mod = b.addModule("json", .{ .root_source_file = b.path("src/json.zig"), .target = target, .optimize = optimize });
    json_mod.addIncludePath(b.path("src/lib"));

    const test_step = b.step("test", "Run package tests");
    const test_exe = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    test_exe.root_module.addImport("json", json_mod);
    test_exe.linkLibrary(lib);

    const run_tests = b.addRunArtifact(test_exe);
    test_step.dependOn(&run_tests.step);
}
