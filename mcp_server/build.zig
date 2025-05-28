const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main server executable
    const server_exe = b.addExecutable(.{
        .name = "mcp_server",
        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(server_exe);

    // Test runner executable
    const test_runner = b.addExecutable(.{
        .name = "test_runner",
        .root_source_file = .{ .cwd_relative = "test_runner.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Directly include test files
    test_runner.addCSourceFile(.{
        .file = .{ .cwd_relative = "src/integration_test.zig" },
        .flags = &.{},
    });

    // Link libc for process handling
    test_runner.linkLibC();

    // Set up test command
    const test_cmd = b.addRunArtifact(test_runner);
    const test_step = b.step("test", "Run integration tests");
    test_step.dependOn(&test_cmd.step);
}
