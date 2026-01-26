//! hello_mcp.zig - A simple MCP server example
//!
//! This example demonstrates the basic structure of an MCP server with:
//! - Simple tool registration
//! - Basic request handling
//! - Stdio transport (default for MCP)
//!
//! Run with: zig run examples/hello_mcp.zig
//! Or test with an MCP client like Claude Desktop

const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== MCP Hello Server ===\n", .{});
    std.debug.print("Starting MCP server with stdio transport...\n\n", .{});

    var server = try mcp.MCPServer.init(allocator);
    defer server.deinit();

    try server.registerTool(.{
        .name = "hello",
        .description = "Returns a greeting message",
        .handler = helloHandler,
        .input_schema = null,
    });

    try server.registerTool(.{
        .name = "echo",
        .description = "Echoes back the input message",
        .handler = echoHandler,
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "message": {
        \\      "type": "string",
        \\      "description": "The message to echo back"
        \\    }
        \\  },
        \\  "required": ["message"]
        \\}
        ,
    });

    try server.registerTool(.{
        .name = "get_time",
        .description = "Returns the current timestamp",
        .handler = timeHandler,
        .input_schema = null,
    });

    std.debug.print("Registered tools: hello, echo, get_time\n", .{});
    std.debug.print("Server is ready. Waiting for MCP client connections...\n", .{});
    std.debug.print("(Press Ctrl+C to stop)\n", .{});

    const stdin_file = std.fs.File.stdin();
    const stdout_file = std.fs.File.stdout();
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var reader = stdin_file.reader(&read_buf);
    var writer = stdout_file.writer(&write_buf);

    while (true) {
        const message = mcp.readContentLengthFrame(allocator, &reader.interface) catch {
            break;
        };
        defer allocator.free(message);

        if (message.len == 0) continue;

        const response = server.handleRequest(message) catch continue;
        defer allocator.free(response);

        if (response.len > 0) {
            mcp.writeContentLengthFrame(&writer.interface, response) catch break;
        }
    }

    std.debug.print("\nServer shutdown complete.\n", .{});
}

fn helloHandler(_: std.mem.Allocator, _: std.json.Value) !std.json.Value {
    return std.json.Value{ .string = "Hello from mcp.zig! 👋" };
}

fn echoHandler(_: std.mem.Allocator, params: std.json.Value) !std.json.Value {
    if (params != .object) {
        return std.json.Value{ .string = "Error: Invalid parameters" };
    }

    const message = params.object.get("message") orelse {
        return std.json.Value{ .string = "Error: 'message' parameter required" };
    };

    if (message != .string) {
        return std.json.Value{ .string = "Error: 'message' must be a string" };
    }

    return std.json.Value{ .string = message.string };
}

fn timeHandler(_: std.mem.Allocator, _: std.json.Value) !std.json.Value {
    const timestamp = std.time.timestamp();
    const time_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{timestamp});
    return std.json.Value{ .string = time_str };
}
