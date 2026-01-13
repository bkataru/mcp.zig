//! MCP Progress Notification Example
//!
//! This example demonstrates how to use the MCP progress notification
//! system to report progress on long-running operations.

const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a progress tracker
    const token = mcp.progress.ProgressToken{ .string = "example-operation" };
    var tracker = mcp.progress.ProgressTracker.init(allocator, token);

    // Create a writer to demonstrate progress updates
    var buffer = std.ArrayList(u8).initCapacity(allocator, 1024);
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator).any();

    // Simulate a long-running operation with progress updates
    std.debug.print("Starting example operation...\n", .{});

    var i: usize = 0;
    while (i <= 100) : (i += 10) {
        // Update progress
        const progress = @as(f64, @floatFromInt(i)) / 100.0;
        const message = try std.fmt.allocPrint(allocator, "Processing step {}", .{i / 10});
        defer allocator.free(message);

        try tracker.update(progress, message, writer);

        // Show the JSON that would be sent
        std.debug.print("Progress notification: {s}\n", .{std.mem.trimRight(u8, buffer.items, "\n")});
        buffer.clearRetainingCapacity();
    }

    // Complete the operation
    try tracker.complete(writer);
    std.debug.print("Completion notification: {s}\n", .{std.mem.trimRight(u8, buffer.items, "\n")});

    std.debug.print("Operation complete!\n", .{});

    // In a real MCP client/server scenario, you would:
    // 1. Send progress notifications to the connected client
    // 2. Use the ProgressBuilder to create proper JSON-RPC notifications
    // 3. Send them over the established connection

    std.debug.print("Progress example completed successfully\n", .{});
}
