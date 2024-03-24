const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("zik", .{
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
}
