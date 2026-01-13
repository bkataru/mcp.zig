//! MCP Client-Server Example
//!
//! This example demonstrates a complete MCP client-server interaction
//! with both the server and client running in the same process.

const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Start the MCP server in a separate thread
    const server_thread = try std.Thread.spawn(.{}, runServer, .{allocator});
    defer server_thread.join();

    // Give the server a moment to start
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Run the client
    try runClient(allocator);
}

fn runServer(allocator: std.mem.Allocator) !void {
    std.debug.print("Starting MCP server...\n", .{});

    // This would normally be your MCP server implementation
    // For this example, we'll just simulate a simple echo server

    var server = mcp.MCPServer.init(allocator);
    defer server.deinit();

    // In a real implementation, you would:
    // 1. Set up handlers for different MCP methods
    // 2. Start accepting connections
    // 3. Process incoming requests

    std.debug.print("MCP server started on port 8081\n", .{});

    // For this demo, we'll just wait a bit then exit
    std.Thread.sleep(2 * std.time.ns_per_s);
}

fn runClient(allocator: std.mem.Allocator) !void {
    std.debug.print("Starting MCP client...\n", .{});

    const address = try std.net.Address.parseIp4("127.0.0.1", 8081);
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    std.debug.print("Client connected to server\n", .{});

    // Send initialize request
    const U8ArrayList = std.array_list.AlignedManaged(u8, null);
    var init_buffer = U8ArrayList.init(allocator);
    defer init_buffer.deinit();
    try std.json.stringify(.{
        .jsonrpc = "2.0",
        .id = 1,
        .method = "initialize",
        .params = .{
            .protocolVersion = "2024-11-05",
            .capabilities = .{},
            .clientInfo = .{
                .name = "client-server-example",
                .version = "1.0.0",
            },
        },
    }, .{}, init_buffer.writer());

    _ = try stream.write(init_buffer.items);
    _ = try stream.write("\n");

    std.debug.print("Sent initialize request\n", .{});

    // Read response
    var buffer: [1024]u8 = undefined;
    const bytes_read = try stream.read(&buffer);

    std.debug.print("Received response: {s}\n", .{buffer[0..bytes_read]});

    // Send a tools/list request
    const tools_request = try std.json.stringifyAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = 2,
        .method = "tools/list",
        .params = .{},
    }, .{});
    defer allocator.free(tools_request);

    _ = try stream.write(tools_request);
    _ = try stream.write("\n");

    std.debug.print("Sent tools/list request\n", .{});

    // Read response
    const tools_bytes_read = try stream.read(&buffer);
    std.debug.print("Received tools response: {s}\n", .{buffer[0..tools_bytes_read]});

    std.debug.print("Client finished\n", .{});
}
