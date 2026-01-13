//! MCP TCP Client Example
//!
//! This example demonstrates how to create an MCP client that connects to a TCP server.
//! Start the TCP server first: zig run examples/tcp_server_example.zig

const std = @import("std");
const net = std.net;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Connect to the TCP server
    const address = try net.Address.parseIp4("127.0.0.1", 8080);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    std.debug.print("Connected to MCP TCP server at {}\n", .{address});

    // Create a simple interactive client
    std.debug.print("Type messages to send to the server (type 'quit' to exit):\n", .{});

    var buffer: [1024]u8 = undefined;
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    while (true) {
        try stdout.writeAll("> ");
        const line = try stdin.readUntilDelimiterOrEof(&buffer, '\n');
        if (line == null) break;

        const message = std.mem.trimRight(u8, line.?, "\r\n");
        if (std.mem.eql(u8, message, "quit")) break;

        // Send message to server
        const message_with_newline = try std.fmt.allocPrint(allocator, "{s}\n", .{message});
        defer allocator.free(message_with_newline);

        _ = try stream.write(message_with_newline);

        // Read response
        const bytes_read = try stream.read(&buffer);
        if (bytes_read == 0) {
            std.debug.print("Server disconnected\n", .{});
            break;
        }

        const response = buffer[0..bytes_read];
        std.debug.print("Server response: {s}", .{response});
    }

    std.debug.print("Disconnected from server\n", .{});
}
