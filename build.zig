const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the library module - this is what external packages will import
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create static library artifact
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "mcp",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // Main server executable module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Server executable can import the library module
    exe_mod.addImport("mcp", lib_mod);

    // Main server executable
    const server_exe = b.addExecutable(.{
        .name = "mcp_server",
        .root_module = exe_mod,
    });
    b.installArtifact(server_exe);

    // Run step
    const run_cmd = b.addRunArtifact(server_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the MCP server");
    run_step.dependOn(&run_cmd.step);

    // Unit tests for the library
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Unit tests for primitives
    const tool_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/primitives/tool.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tool_tests = b.addTest(.{
        .root_module = tool_tests_mod,
    });
    const run_tool_tests = b.addRunArtifact(tool_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_tool_tests.step);
}
