//! MCP TCP Server Example
//!
//! This example demonstrates how to create an MCP server that listens on TCP.
//! Run this server first, then connect with a TCP client.

const std = @import("std");
const net = std.net;
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create MCP server
    var server = try mcp.MCPServer.init(allocator);
    defer server.deinit();

    // Add a simple calculator tool
    try server.registerTool(.{
        .name = "add",
        .description = "Add two numbers together",
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "a": { "type": "number", "description": "First number" },
        \\    "b": { "type": "number", "description": "Second number" }
        \\  },
        \\  "required": ["a", "b"]
        \\}
        ,
        .handler = struct {
            fn handler(alloc: std.mem.Allocator, arguments: std.json.Value) !std.json.Value {
                _ = alloc;

                const a = arguments.object.get("a").?.float;
                const b = arguments.object.get("b").?.float;
                const result = a + b;

                return std.json.Value{ .float = result };
            }
        }.handler,
    });

    // Set up TCP server
    const address = try net.Address.parseIp4("127.0.0.1", 8080);
    var tcp_server = try address.listen(.{});
    defer tcp_server.deinit();

    std.debug.print("MCP TCP server listening on 127.0.0.1:8080\n", .{});
    std.debug.print("Connect with: zig run examples/tcp_client_example.zig\n", .{});

    // Accept connections
    while (true) {
        const connection = tcp_server.accept() catch |err| {
            std.debug.print("Failed to accept connection: {any}\n", .{err});
            continue;
        };

        std.debug.print("New client connected from {any}\n", .{connection.address});

        // Handle connection in a new thread
        const thread = try std.Thread.spawn(.{}, handleConnection, .{ connection.stream, &server, allocator });
        thread.detach();
    }
}

fn handleConnection(stream: net.Stream, server: *mcp.MCPServer, allocator: std.mem.Allocator) !void {
    _ = server; // TODO: Use server for actual MCP protocol handling
    // Create a simple line-based protocol handler
    var buffer: [4096]u8 = undefined;

    while (true) {
        const bytes_read = stream.read(&buffer) catch break;
        if (bytes_read == 0) break;

        const message = std.mem.trimRight(u8, buffer[0..bytes_read], "\r\n");
        if (std.mem.eql(u8, message, "quit")) break;

        std.debug.print("Received: {s}\n", .{message});

        // For this simple example, just echo back
        const response = try std.fmt.allocPrint(allocator, "Echo: {s}\n", .{message});
        defer allocator.free(response);

        _ = stream.write(response) catch break;
    }

    stream.close();
    std.debug.print("Client disconnected\n", .{});
}
