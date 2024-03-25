pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zik", .{
        .root_source_file = .{ .path = "src/root.zig" },
    });

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/root.zig" },
    });
    const test_step = b.step("test", "Run library tests");
    if (b.option(bool, "install-tests", "Install test binary rather than running it") orelse false) {
        test_step.dependOn(&b.addInstallArtifact(tests, .{}).step);
    } else {
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const prof = b.addExecutable(.{
        .name = "zikprof",
        .root_source_file = .{ .path = "tools/zikprof.zig" },
        .target = target,
        .optimize = optimize,
    });
    prof.root_module.addImport("zik", mod);
    b.step("zikprof", "Build the zikprof profiler").dependOn(&b.addInstallArtifact(prof, .{}).step);
}

const std = @import("std");
