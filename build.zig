const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the library module - this is what external packages will import
    const lib_mod = b.addModule("mcp", .{
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

    // Test client executable module
    const test_client_mod = b.createModule(.{
        .root_source_file = b.path("src/test_client.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Test client executable
    const test_client_exe = b.addExecutable(.{
        .name = "test_client",
        .root_module = test_client_mod,
    });
    b.installArtifact(test_client_exe);

    // Run server step
    const run_cmd = b.addRunArtifact(server_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the MCP server");
    run_step.dependOn(&run_cmd.step);

    // Run test client step
    const run_test_client = b.addRunArtifact(test_client_exe);
    run_test_client.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_test_client.addArgs(args);
    }
    const test_client_step = b.step("test-client", "Run the integration test client");
    test_client_step.dependOn(&run_test_client.step);

    // Example: Resource Subscriptions
    const example_resource_subscriptions_mod = b.createModule(.{
        .root_source_file = b.path("examples/resource_subscriptions.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_resource_subscriptions_mod.addImport("mcp", lib_mod);

    const example_resource_subscriptions_exe = b.addExecutable(.{
        .name = "resource_subscriptions_example",
        .root_module = example_resource_subscriptions_mod,
    });
    b.installArtifact(example_resource_subscriptions_exe);

    const run_example_subscriptions = b.addRunArtifact(example_resource_subscriptions_exe);
    run_example_subscriptions.step.dependOn(b.getInstallStep());
    const example_subscriptions_step = b.step("example-subscriptions", "Run resource subscriptions example");
    example_subscriptions_step.dependOn(&run_example_subscriptions.step);

    // Integration Test
    const integration_test_mod = b.createModule(.{
        .root_source_file = b.path("examples/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_test_mod.addImport("mcp", lib_mod);

    const integration_test_exe = b.addExecutable(.{
        .name = "integration_test",
        .root_module = integration_test_mod,
    });
    b.installArtifact(integration_test_exe);

    const run_integration_test = b.addRunArtifact(integration_test_exe);
    run_integration_test.step.dependOn(b.getInstallStep());
    const integration_test_step = b.step("integration-test", "Run MCP integration tests");
    integration_test_step.dependOn(&run_integration_test.step);

    // Async Progress Example
    const async_progress_mod = b.createModule(.{
        .root_source_file = b.path("examples/async_progress_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    async_progress_mod.addImport("mcp", lib_mod);

    const async_progress_exe = b.addExecutable(.{
        .name = "async_progress_example",
        .root_module = async_progress_mod,
    });
    b.installArtifact(async_progress_exe);

    const run_async_progress = b.addRunArtifact(async_progress_exe);
    run_async_progress.step.dependOn(b.getInstallStep());
    const async_progress_step = b.step("example-async-progress", "Run async progress notification example");
    async_progress_step.dependOn(&run_async_progress.step);

    // Sampling Example
    const sampling_mod = b.createModule(.{
        .root_source_file = b.path("examples/sampling_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    sampling_mod.addImport("mcp", lib_mod);

    const sampling_exe = b.addExecutable(.{
        .name = "sampling_example",
        .root_module = sampling_mod,
    });
    b.installArtifact(sampling_exe);

    const run_sampling = b.addRunArtifact(sampling_exe);
    run_sampling.step.dependOn(b.getInstallStep());
    const sampling_step = b.step("example-sampling", "Run MCP sampling example");
    sampling_step.dependOn(&run_sampling.step);

    // Cancellation Example
    const cancellation_mod = b.createModule(.{
        .root_source_file = b.path("examples/cancellation_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    cancellation_mod.addImport("mcp", lib_mod);

    const cancellation_exe = b.addExecutable(.{
        .name = "cancellation_example",
        .root_module = cancellation_mod,
    });
    b.installArtifact(cancellation_exe);

    const run_cancellation = b.addRunArtifact(cancellation_exe);
    run_cancellation.step.dependOn(b.getInstallStep());
    const cancellation_step = b.step("example-cancellation", "Run MCP request cancellation example");
    cancellation_step.dependOn(&run_cancellation.step);

    // Resource Templates Example
    const resource_templates_mod = b.createModule(.{
        .root_source_file = b.path("examples/resource_templates_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    resource_templates_mod.addImport("mcp", lib_mod);

    const resource_templates_exe = b.addExecutable(.{
        .name = "resource_templates_example",
        .root_module = resource_templates_mod,
    });
    b.installArtifact(resource_templates_exe);

    const run_resource_templates = b.addRunArtifact(resource_templates_exe);
    run_resource_templates.step.dependOn(b.getInstallStep());
    const resource_templates_step = b.step("example-resource-templates", "Run MCP resource templates example");
    resource_templates_step.dependOn(&run_resource_templates.step);

    // Client-Server Example
    const client_server_mod = b.createModule(.{
        .root_source_file = b.path("examples/client_server_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_server_mod.addImport("mcp", lib_mod);

    const client_server_exe = b.addExecutable(.{
        .name = "client_server_example",
        .root_module = client_server_mod,
    });
    b.installArtifact(client_server_exe);

    const run_client_server = b.addRunArtifact(client_server_exe);
    run_client_server.step.dependOn(b.getInstallStep());
    const client_server_step = b.step("example-client-server", "Run MCP client-server interaction example");
    client_server_step.dependOn(&run_client_server.step);

    // Progress Example
    const progress_mod = b.createModule(.{
        .root_source_file = b.path("examples/progress_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    progress_mod.addImport("mcp", lib_mod);

    const progress_exe = b.addExecutable(.{
        .name = "progress_example",
        .root_module = progress_mod,
    });
    b.installArtifact(progress_exe);

    const run_progress = b.addRunArtifact(progress_exe);
    run_progress.step.dependOn(b.getInstallStep());
    const progress_step = b.step("example-progress", "Run MCP progress notification example");
    progress_step.dependOn(&run_progress.step);

    // MCP Client Example
    const mcp_client_mod = b.createModule(.{
        .root_source_file = b.path("examples/mcp_client_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    mcp_client_mod.addImport("mcp", lib_mod);

    const mcp_client_exe = b.addExecutable(.{
        .name = "mcp_client_example",
        .root_module = mcp_client_mod,
    });
    b.installArtifact(mcp_client_exe);

    const run_mcp_client = b.addRunArtifact(mcp_client_exe);
    run_mcp_client.step.dependOn(b.getInstallStep());
    const mcp_client_step = b.step("example-mcp-client", "Run MCP client example");
    mcp_client_step.dependOn(&run_mcp_client.step);

    // TCP Client Example
    const tcp_client_mod = b.createModule(.{
        .root_source_file = b.path("examples/tcp_client_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    tcp_client_mod.addImport("mcp", lib_mod);

    const tcp_client_exe = b.addExecutable(.{
        .name = "tcp_client_example",
        .root_module = tcp_client_mod,
    });
    b.installArtifact(tcp_client_exe);

    const run_tcp_client = b.addRunArtifact(tcp_client_exe);
    run_tcp_client.step.dependOn(b.getInstallStep());
    const tcp_client_step = b.step("example-tcp-client", "Run TCP client example");
    tcp_client_step.dependOn(&run_tcp_client.step);

    // TCP Server Example
    const tcp_server_mod = b.createModule(.{
        .root_source_file = b.path("examples/tcp_server_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    tcp_server_mod.addImport("mcp", lib_mod);

    const tcp_server_exe = b.addExecutable(.{
        .name = "tcp_server_example",
        .root_module = tcp_server_mod,
    });
    b.installArtifact(tcp_server_exe);

    const run_tcp_server = b.addRunArtifact(tcp_server_exe);
    run_tcp_server.step.dependOn(b.getInstallStep());
    const tcp_server_step = b.step("example-tcp-server", "Run TCP server example");
    tcp_server_step.dependOn(&run_tcp_server.step);

    // TCP Full Example
    const tcp_full_mod = b.createModule(.{
        .root_source_file = b.path("examples/tcp_full_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    tcp_full_mod.addImport("mcp", lib_mod);

    const tcp_full_exe = b.addExecutable(.{
        .name = "tcp_full_example",
        .root_module = tcp_full_mod,
    });
    b.installArtifact(tcp_full_exe);

    const run_tcp_full = b.addRunArtifact(tcp_full_exe);
    run_tcp_full.step.dependOn(b.getInstallStep());
    const tcp_full_step = b.step("example-tcp-full", "Run full TCP client-server example");
    tcp_full_step.dependOn(&run_tcp_full.step);

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
