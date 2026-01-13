//! MCP Async Progress Notification Example
//!
//! This example demonstrates how to use the async progress notification
//! system to deliver progress updates in the background without blocking
//! the main execution thread.

const std = @import("std");
const mcp = @import("mcp");

/// Example context for the notification callback
const NotificationContext = struct {
    total_notifications: std.atomic.Value(usize),

    fn init() @This() {
        return .{
            .total_notifications = std.atomic.Value(usize).init(0),
        };
    }
};

/// Notification callback function
fn progressCallback(notification_json: []const u8, context: ?*anyopaque) void {
    const ctx = @as(*NotificationContext, @ptrCast(@alignCast(context.?)));
    const count = ctx.total_notifications.fetchAdd(1, .monotonic);

    std.debug.print("📊 Progress notification #{d}: {s}\n", .{ count + 1, notification_json });

    // In a real application, this could send the notification over a network
    // connection, write to a log file, update a UI, etc.
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🚀 Starting Async Progress Notification Demo\n", .{});

    // Create notification context
    var context = NotificationContext.init();

    // Create async progress notifier
    var notifier = try mcp.progress.ProgressNotifier.init(allocator, progressCallback, &context);
    defer notifier.deinit();

    // Start the async notification delivery
    try notifier.start();
    std.debug.print("✅ Started async progress notification delivery\n", .{});

    // Create a progress tracker with async notification support
    const token = mcp.progress.ProgressToken{ .string = "async-demo-operation" };
    var tracker = mcp.progress.ProgressTracker.initWithNotifier(allocator, token, notifier);

    std.debug.print("🔄 Starting simulated long-running operation...\n", .{});

    // Simulate a long-running operation with progress updates
    var i: usize = 0;
    while (i <= 100) : (i += 20) {
        const progress = @as(f64, @floatFromInt(i)) / 100.0;
        const message = try std.fmt.allocPrint(allocator, "Processing step {d}/5", .{i / 20 + 1});
        defer allocator.free(message);

        // Send progress update asynchronously - this won't block!
        try tracker.updateAsync(progress, message);

        std.debug.print("📈 Sent async progress update: {d}%\n", .{i});

        // Simulate work that takes some time
        std.Thread.sleep(200 * std.time.ns_per_ms);
    }

    // Complete the operation asynchronously
    try tracker.completeAsync();
    std.debug.print("✅ Sent async completion notification\n", .{});

    // Wait a bit for all notifications to be delivered
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Stop the notifier
    notifier.stop();

    const total_notifications = context.total_notifications.load(.monotonic);
    std.debug.print("🎉 Demo complete! Delivered {d} progress notifications asynchronously.\n", .{total_notifications});

    std.debug.print("\n💡 Key Benefits of Async Progress Notifications:\n", .{});
    std.debug.print("   • Non-blocking: Progress updates don't interrupt main execution\n", .{});
    std.debug.print("   • Scalable: Multiple operations can report progress simultaneously\n", .{});
    std.debug.print("   • Flexible: Notifications can be sent to any destination (network, UI, logs)\n", .{});
    std.debug.print("   • Reliable: Queued delivery ensures no progress updates are lost\n", .{});
}
