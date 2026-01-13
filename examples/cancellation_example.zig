//! MCP Request Cancellation Example
//!
//! This example demonstrates how to cancel in-flight requests in MCP.
//! It shows both the server-side cancellation handling and client-side
//! request cancellation.

const std = @import("std");
const mcp = @import("mcp");

/// Helper to create JSON request strings
fn createJsonRequest(allocator: std.mem.Allocator, request: anytype) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &out.writer,
    };
    try stringify.write(request);
    return try out.toOwnedSlice();
}

/// Example tool that simulates a long-running operation that can be cancelled
fn longRunningTool(allocator: std.mem.Allocator, args: std.json.Value, cancellation_token: ?*mcp.CancellationToken) !std.json.Value {
    const duration_value = args.object.get("duration_seconds").?;
    const duration_seconds = switch (duration_value) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.InvalidDurationType,
    };

    std.debug.print("🕐 Starting long-running operation for {d} seconds...\n", .{duration_seconds});

    // Simulate work that can be cancelled
    var i: usize = 0;
    const total_iterations = @as(usize, @intFromFloat(duration_seconds * 10));

    while (i < total_iterations) : (i += 1) {
        // Check for cancellation
        if (cancellation_token) |token| {
            if (token.isCancelled()) {
                const reason = token.reason orelse "No reason provided";
                std.debug.print("❌ Operation cancelled: {s}\n", .{reason});
                return std.json.Value{ .string = "Operation cancelled" };
            }
        }

        // Simulate work
        std.Thread.sleep(100 * std.time.ns_per_ms);

        // Progress indicator
        if (i % 10 == 0) {
            std.debug.print("📊 Progress: {d}%\n", .{i * 100 / total_iterations});
        }
    }

    const result = try std.fmt.allocPrint(allocator, "Operation completed after {d} seconds", .{duration_seconds});
    return std.json.Value{ .string = result };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🚫 MCP Request Cancellation Demo\n\n", .{});

    // Create MCP server
    var server = try mcp.MCPServer.init(allocator);
    defer server.deinit();

    // Register the long-running tool with cancellation support
    try server.registerTool(.{
        .name = "long_running_task",
        .description = "A task that takes time and can be cancelled",
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "duration_seconds": { "type": "number", "description": "How long to run" }
        \\  },
        \\  "required": ["duration_seconds"]
        \\}
        ,
        .handler = struct {
            fn handler(alloc: std.mem.Allocator, params: std.json.Value) !std.json.Value {
                return try longRunningTool(alloc, params, null);
            }
        }.handler,
        .handler_with_cancellation = struct {
            fn handler(alloc: std.mem.Allocator, params: std.json.Value, cancellation_token: ?*mcp.CancellationToken) !std.json.Value {
                return try longRunningTool(alloc, params, cancellation_token);
            }
        }.handler,
    });

    std.debug.print("✅ Registered long-running tool\n", .{});

    // Initialize the server first
    const init_request = try createJsonRequest(allocator, .{ .jsonrpc = "2.0", .id = 0, .method = "initialize", .params = .{
        .protocolVersion = "2025-11-25",
        .capabilities = .{},
        .clientInfo = .{ .name = "cancellation-test", .version = "1.0.0" },
    } });
    defer allocator.free(init_request);

    const init_response = try server.handleRequest(init_request);
    defer allocator.free(init_response);
    std.debug.print("Init response: {s}\n", .{init_response});
    std.debug.print("✅ Server initialized\n", .{});

    // Demonstrate cancellation by simulating client requests

    std.debug.print("\n🔄 Simulating normal completion:\n", .{});

    // Test 1: Normal completion (short duration)
    var short_out: std.io.Writer.Allocating = .init(allocator);
    defer short_out.deinit();
    var short_stringify: std.json.Stringify = .{
        .writer = &short_out.writer,
    };
    try short_stringify.write(.{
        .jsonrpc = "2.0",
        .id = 1,
        .method = "tools/call",
        .params = .{
            .name = "long_running_task",
            .arguments = .{ .duration_seconds = 1.0 },
        },
    });
    const short_request = try short_out.toOwnedSlice();
    defer allocator.free(short_request);

    const short_response = try server.handleRequest(short_request);
    defer allocator.free(short_response);
    std.debug.print("✅ Short task completed: {s}\n", .{short_response});

    std.debug.print("\n🚫 Simulating request cancellation:\n", .{});

    // Test 2: Simulate cancellation
    // Start a long-running request in a separate thread
    var long_out: std.io.Writer.Allocating = .init(allocator);
    defer long_out.deinit();
    var long_stringify: std.json.Stringify = .{
        .writer = &long_out.writer,
    };
    try long_stringify.write(.{
        .jsonrpc = "2.0",
        .id = 2,
        .method = "tools/call",
        .params = .{
            .name = "long_running_task",
            .arguments = .{ .duration_seconds = 3.0 },
        },
    });
    const long_request_json = try long_out.toOwnedSlice();
    defer allocator.free(long_request_json);

    // Start the long request in a background thread
    const handle = try std.Thread.spawn(.{}, handleRequestAsync, .{ &server, long_request_json });
    defer handle.join();

    // Wait a bit then send cancellation
    std.Thread.sleep(500 * std.time.ns_per_ms);

    std.debug.print("📤 Sending cancellation notification...\n", .{});

    // Send cancellation notification
    var cancel_out: std.io.Writer.Allocating = .init(allocator);
    defer cancel_out.deinit();
    var cancel_stringify: std.json.Stringify = .{
        .writer = &cancel_out.writer,
    };
    try cancel_stringify.write(.{
        .jsonrpc = "2.0",
        .method = "notifications/cancelled",
        .params = .{
            .requestId = .{ .integer = 2 },
            .reason = "Demo cancellation",
        },
    });
    const cancel_notification = try cancel_out.toOwnedSlice();
    defer allocator.free(cancel_notification);
    std.debug.print("Cancel notification: {s}\n", .{cancel_notification});

    const cancel_response = try server.handleRequest(cancel_notification);
    defer allocator.free(cancel_response);

    // Wait for the background thread to finish
    std.Thread.sleep(500 * std.time.ns_per_ms);

    std.debug.print("\n💡 Key Benefits of Request Cancellation:\n", .{});
    std.debug.print("   • Interrupt long-running operations\n", .{});
    std.debug.print("   • Improve user experience with responsive UIs\n", .{});
    std.debug.print("   • Prevent resource waste on abandoned requests\n", .{});
    std.debug.print("   • Enable timeout-based cancellation\n", .{});

    std.debug.print("\n🎉 Cancellation demo completed!\n", .{});
}

fn handleRequestAsync(server: *mcp.MCPServer, request_json: []const u8) void {
    const response = server.handleRequest(request_json) catch |err| {
        std.debug.print("Request failed: {any}\n", .{err});
        return;
    };
    defer server.parent_allocator.free(response);
    std.debug.print("📥 Long request response: {s}\n", .{response});
}
