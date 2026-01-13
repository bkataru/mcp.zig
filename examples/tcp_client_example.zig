//! MCP TCP Client Example
//!
//! This example demonstrates how to create an MCP client that connects to a TCP server.
//! Start the TCP server first: zig run examples/tcp_server_example.zig

const std = @import("std");
const net = std.net;

pub fn main() !void {
    // Connect to the TCP server
    const address = try net.Address.parseIp4("127.0.0.1", 8080);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    std.debug.print("Connected to MCP TCP server at {any}\n", .{address});

    // Send a test message
    const test_message = "Hello from MCP client!\n";
    _ = try stream.write(test_message);

    // Read response
    var buffer: [1024]u8 = undefined;
    const bytes_read = try stream.read(&buffer);
    if (bytes_read == 0) {
        std.debug.print("Server disconnected\n", .{});
        return;
    }

    const response = buffer[0..bytes_read];
    std.debug.print("Server response: {s}\n", .{response});

    std.debug.print("Disconnected from server\n", .{});
}
