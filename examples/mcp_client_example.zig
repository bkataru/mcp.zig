//! MCP Client Example
//!
//! This example demonstrates how to create a minimal MCP client that connects
//! to an MCP server over TCP and sends basic requests.

const std = @import("std");
const net = std.net;
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a simple TCP client
    const address = try net.Address.parseIp4("127.0.0.1", 8080);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    std.debug.print("Connected to MCP server at {any}\n", .{address});

    // Create a basic initialize request
    const request_json = .{
        .jsonrpc = "2.0",
        .id = 1,
        .method = "initialize",
        .params = .{
            .protocolVersion = "2024-11-05",
            .capabilities = .{},
            .clientInfo = .{
                .name = "mcp-client-example",
                .version = "1.0.0",
            },
        },
    };

    const U8ArrayList = std.array_list.AlignedManaged(u8, null);
    var request_buffer = U8ArrayList.init(allocator);
    defer request_buffer.deinit();
    try std.json.stringify(request_json, .{}, request_buffer.writer());

    // Send the request
    const request_with_newline = try std.fmt.allocPrint(allocator, "{s}\n", .{request_buffer.items});
    defer allocator.free(request_with_newline);

    _ = try stream.write(request_with_newline);

    std.debug.print("Sent initialize request\n", .{});

    // Read response
    var buffer: [4096]u8 = undefined;
    const bytes_read = try stream.read(&buffer);
    const response = buffer[0..bytes_read];

    std.debug.print("Received response: {s}\n", .{response});
}
