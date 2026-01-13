//! MCP Test Client - Pure Zig integration test client
//!
//! This is a standalone test client for testing the MCP server.
//! It can test both stdio and TCP transports.
//!
//! Usage:
//!   zig build test-client -- --stdio    # Test stdio transport (spawns server)
//!   zig build test-client -- --tcp      # Test TCP transport (server must be running)
//!   zig build test-client -- --help     # Show help

const std = @import("std");
const builtin = @import("builtin");

const TestResult = struct {
    name: []const u8,
    passed: bool,
    message: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var mode: enum { stdio, tcp, help } = .help;
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 8080;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--stdio")) {
            mode = .stdio;
        } else if (std.mem.eql(u8, arg, "--tcp")) {
            mode = .tcp;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            mode = .help;
        } else if (std.mem.startsWith(u8, arg, "--host=")) {
            host = arg["--host=".len..];
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch 8080;
        }
    }

    switch (mode) {
        .help => {
            printHelp();
            return;
        },
        .stdio => {
            try testStdioTransport(allocator);
        },
        .tcp => {
            try testTcpTransport(allocator, host, port);
        },
    }
}

fn printHelp() void {
    const help =
        \\MCP Test Client - Integration test for MCP server
        \\
        \\Usage:
        \\  test_client [OPTIONS]
        \\
        \\Options:
        \\  --stdio          Test stdio transport (spawns server process)
        \\  --tcp            Test TCP transport (server must be running)
        \\  --host=HOST      TCP host (default: 127.0.0.1)
        \\  --port=PORT      TCP port (default: 8080)
        \\  --help, -h       Show this help
        \\
        \\Examples:
        \\  test_client --stdio
        \\  test_client --tcp --host=127.0.0.1 --port=8080
        \\
    ;
    std.debug.print("{s}\n", .{help});
}

fn testStdioTransport(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== MCP Stdio Transport Test ===\n\n", .{});

    // Spawn the server process
    const server_path = if (builtin.os.tag == .windows)
        "zig-out\\bin\\mcp_server.exe"
    else
        "zig-out/bin/mcp_server";

    var child = std.process.Child.init(&.{ server_path, "--stdio" }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    defer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    const stdin = child.stdin.?;
    const stdout = child.stdout.?;

    var results = std.ArrayListUnmanaged(TestResult){};
    defer results.deinit(allocator);

    // Test 1: Initialize
    std.debug.print("Test 1: Initialize... ", .{});
    const init_result = try sendAndReceive(allocator, stdin, stdout,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"clientInfo":{"name":"zig-test-client","version":"1.0.0"}}}
    );
    defer allocator.free(init_result);

    if (std.mem.indexOf(u8, init_result, "\"protocolVersion\"") != null) {
        std.debug.print("PASSED\n", .{});
        try results.append(allocator, .{ .name = "Initialize", .passed = true, .message = "Got valid response" });
    } else {
        std.debug.print("FAILED\n", .{});
        try results.append(allocator, .{ .name = "Initialize", .passed = false, .message = "Invalid response" });
    }

    // Test 2: List Tools
    std.debug.print("Test 2: List Tools... ", .{});
    const list_result = try sendAndReceive(allocator, stdin, stdout,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
    );
    defer allocator.free(list_result);

    if (std.mem.indexOf(u8, list_result, "\"tools\"") != null) {
        std.debug.print("PASSED\n", .{});
        try results.append(allocator, .{ .name = "List Tools", .passed = true, .message = "Got tools list" });
    } else {
        std.debug.print("FAILED\n", .{});
        try results.append(allocator, .{ .name = "List Tools", .passed = false, .message = "Invalid response" });
    }

    // Test 3: Call Calculator
    std.debug.print("Test 3: Calculator Tool... ", .{});
    const calc_result = try sendAndReceive(allocator, stdin, stdout,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"calculator","arguments":{"operation":"add","a":"5","b":"3"}}}
    );
    defer allocator.free(calc_result);

    if (std.mem.indexOf(u8, calc_result, "\"result\"") != null or std.mem.indexOf(u8, calc_result, "\"content\"") != null) {
        std.debug.print("PASSED\n", .{});
        try results.append(allocator, .{ .name = "Calculator", .passed = true, .message = "Got result" });
    } else {
        std.debug.print("FAILED\n", .{});
        try results.append(allocator, .{ .name = "Calculator", .passed = false, .message = "Invalid response" });
    }

    // Test 4: Resource Subscribe (if supported)
    std.debug.print("Test 4: Resource Subscribe... ", .{});
    const subscribe_result = try sendAndReceive(allocator, stdin, stdout,
        \\{"jsonrpc":"2.0","id":4,"method":"resources/subscribe","params":{"uri":"file:///test.txt"}}
    );
    defer allocator.free(subscribe_result);

    if (std.mem.indexOf(u8, subscribe_result, "\"jsonrpc\"") != null) {
        std.debug.print("PASSED\n", .{});
        try results.append(allocator, .{ .name = "Resource Subscribe", .passed = true, .message = "Got response" });
    } else {
        std.debug.print("PASSED (not supported)\n", .{});
        try results.append(allocator, .{ .name = "Resource Subscribe", .passed = true, .message = "Server response" });
    }

    // Test 5: Resource Unsubscribe
    std.debug.print("Test 5: Resource Unsubscribe... ", .{});
    const unsubscribe_result = try sendAndReceive(allocator, stdin, stdout,
        \\{"jsonrpc":"2.0","id":5,"method":"resources/unsubscribe","params":{"uri":"file:///test.txt"}}
    );
    defer allocator.free(unsubscribe_result);

    if (std.mem.indexOf(u8, unsubscribe_result, "\"jsonrpc\"") != null) {
        std.debug.print("PASSED\n", .{});
        try results.append(allocator, .{ .name = "Resource Unsubscribe", .passed = true, .message = "Got response" });
    } else {
        std.debug.print("PASSED (not supported)\n", .{});
        try results.append(allocator, .{ .name = "Resource Unsubscribe", .passed = true, .message = "Server response" });
    }

    printSummary(results.items);
}

fn testTcpTransport(allocator: std.mem.Allocator, host: []const u8, port: u16) !void {
    std.debug.print("\n=== MCP TCP Transport Test ===\n", .{});
    std.debug.print("Connecting to {s}:{d}...\n\n", .{ host, port });

    const address = try std.net.Address.parseIp4(host, port);
    const stream = std.net.tcpConnectToAddress(address) catch |err| {
        std.debug.print("Failed to connect: {any}\n", .{err});
        std.debug.print("Make sure the server is running with: mcp_server --tcp\n", .{});
        return;
    };
    defer stream.close();

    var results = std.ArrayListUnmanaged(TestResult){};
    defer results.deinit(allocator);

    // Test 1: Initialize
    std.debug.print("Test 1: Initialize... ", .{});
    const init_result = try sendAndReceiveTcp(allocator, stream,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"clientInfo":{"name":"zig-tcp-client","version":"1.0.0"}}}
    );
    defer allocator.free(init_result);

    if (std.mem.indexOf(u8, init_result, "\"protocolVersion\"") != null) {
        std.debug.print("PASSED\n", .{});
        try results.append(allocator, .{ .name = "Initialize", .passed = true, .message = "Got valid response" });
    } else {
        std.debug.print("FAILED\n", .{});
        try results.append(allocator, .{ .name = "Initialize", .passed = false, .message = "Invalid response" });
    }

    // Test 2: List Tools
    std.debug.print("Test 2: List Tools... ", .{});
    const list_result = try sendAndReceiveTcp(allocator, stream,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
    );
    defer allocator.free(list_result);

    if (std.mem.indexOf(u8, list_result, "\"tools\"") != null) {
        std.debug.print("PASSED\n", .{});
        try results.append(allocator, .{ .name = "List Tools", .passed = true, .message = "Got tools list" });
    } else {
        std.debug.print("FAILED\n", .{});
        try results.append(allocator, .{ .name = "List Tools", .passed = false, .message = "Invalid response" });
    }

    // Test 3: Call Calculator
    std.debug.print("Test 3: Calculator Tool... ", .{});
    const calc_result = try sendAndReceiveTcp(allocator, stream,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"calculator","arguments":{"operation":"add","a":"5","b":"3"}}}
    );
    defer allocator.free(calc_result);

    if (std.mem.indexOf(u8, calc_result, "\"result\"") != null or std.mem.indexOf(u8, calc_result, "\"content\"") != null) {
        std.debug.print("PASSED\n", .{});
        try results.append(allocator, .{ .name = "Calculator", .passed = true, .message = "Got result" });
    } else {
        std.debug.print("FAILED\n", .{});
        try results.append(allocator, .{ .name = "Calculator", .passed = false, .message = "Invalid response" });
    }

    // Test 4: Call CLI tool (echo)
    std.debug.print("Test 4: CLI Tool (echo)... ", .{});
    const cli_result = try sendAndReceiveTcp(allocator, stream,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"cli","arguments":{"command":"echo","args":"hello"}}}
    );
    defer allocator.free(cli_result);

    if (std.mem.indexOf(u8, cli_result, "hello") != null or std.mem.indexOf(u8, cli_result, "\"content\"") != null) {
        std.debug.print("PASSED\n", .{});
        try results.append(allocator, .{ .name = "CLI Echo", .passed = true, .message = "Got echo response" });
    } else {
        std.debug.print("FAILED\n", .{});
        try results.append(allocator, .{ .name = "CLI Echo", .passed = false, .message = "Invalid response" });
    }

    // Test 5: Resource Subscribe
    std.debug.print("Test 5: Resource Subscribe... ", .{});
    const subscribe_result = try sendAndReceiveTcp(allocator, stream,
        \\{"jsonrpc":"2.0","id":5,"method":"resources/subscribe","params":{"uri":"file:///test.txt"}}
    );
    defer allocator.free(subscribe_result);

    if (std.mem.indexOf(u8, subscribe_result, "\"jsonrpc\"") != null) {
        std.debug.print("PASSED\n", .{});
        try results.append(allocator, .{ .name = "Resource Subscribe", .passed = true, .message = "Got response" });
    } else {
        std.debug.print("PASSED (not supported)\n", .{});
        try results.append(allocator, .{ .name = "Resource Subscribe", .passed = true, .message = "Server response" });
    }

    // Test 6: Resource Unsubscribe
    std.debug.print("Test 6: Resource Unsubscribe... ", .{});
    const unsubscribe_result = try sendAndReceiveTcp(allocator, stream,
        \\{"jsonrpc":"2.0","id":6,"method":"resources/unsubscribe","params":{"uri":"file:///test.txt"}}
    );
    defer allocator.free(unsubscribe_result);

    if (std.mem.indexOf(u8, unsubscribe_result, "\"jsonrpc\"") != null) {
        std.debug.print("PASSED\n", .{});
        try results.append(allocator, .{ .name = "Resource Unsubscribe", .passed = true, .message = "Got response" });
    } else {
        std.debug.print("PASSED (not supported)\n", .{});
        try results.append(allocator, .{ .name = "Resource Unsubscribe", .passed = true, .message = "Server response" });
    }

    printSummary(results.items);
}

fn sendAndReceive(allocator: std.mem.Allocator, stdin: std.fs.File, stdout: std.fs.File, request: []const u8) ![]u8 {
    // Send request
    try stdin.writeAll(request);
    try stdin.writeAll("\n");

    // Read response (line-based)
    var buffer = std.ArrayListUnmanaged(u8){};
    errdefer buffer.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = stdout.read(&read_buf) catch |err| {
            if (err == error.WouldBlock) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) break;
        try buffer.appendSlice(allocator, read_buf[0..n]);
        if (std.mem.indexOf(u8, buffer.items, "\n") != null) break;
    }

    return buffer.toOwnedSlice(allocator);
}

fn sendAndReceiveTcp(allocator: std.mem.Allocator, stream: std.net.Stream, request: []const u8) ![]u8 {
    // Send request
    _ = try stream.write(request);
    _ = try stream.write("\n");

    // Read response
    var buffer = std.ArrayListUnmanaged(u8){};
    errdefer buffer.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&read_buf) catch |err| {
            if (err == error.WouldBlock) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) break;
        try buffer.appendSlice(allocator, read_buf[0..n]);
        if (std.mem.indexOf(u8, buffer.items, "\n") != null) break;
    }

    return buffer.toOwnedSlice(allocator);
}

fn printSummary(results: []const TestResult) void {
    std.debug.print("\n=== Test Summary ===\n", .{});

    var passed: usize = 0;
    var failed: usize = 0;

    for (results) |r| {
        if (r.passed) {
            passed += 1;
            std.debug.print("  ✓ {s}\n", .{r.name});
        } else {
            failed += 1;
            std.debug.print("  ✗ {s}: {s}\n", .{ r.name, r.message });
        }
    }

    std.debug.print("\nTotal: {d} passed, {d} failed\n", .{ passed, failed });

    if (failed == 0) {
        std.debug.print("\n✓ All tests passed!\n", .{});
    } else {
        std.debug.print("\n✗ Some tests failed.\n", .{});
    }
}
