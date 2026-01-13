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

    // Simulate a long-running operation with progress updates
    std.debug.print("Starting example operation...\n", .{});

    // Note: In real usage, progress notifications would be sent to the client.
    // For this example, we'll just demonstrate the progress tracking logic.

    var i: usize = 0;
    while (i <= 100) : (i += 10) {
        // Update progress
        const progress = @as(f64, @floatFromInt(i)) / 100.0;
        const message = try std.fmt.allocPrint(allocator, "Processing step {d}", .{i / 10});
        defer allocator.free(message);

        // In real usage: _ = try tracker.update(progress, message, writer);
        _ = progress;
        _ = &tracker;
        std.debug.print("Progress: {d}% - {s}\n", .{ i, message });
    }

    // Complete the operation
    // In real usage: _ = try tracker.complete(writer);
    std.debug.print("Operation complete!\n", .{});

    // In a real MCP client/server scenario, you would:
    // 1. Send progress notifications to the connected client
    // 2. Use the ProgressBuilder to create proper JSON-RPC notifications
    // 3. Send them over the established connection

    std.debug.print("Progress example completed successfully\n", .{});
}
