//! Example: Resource Subscriptions with mcp.zig
//!
//! This example demonstrates how to:
//! 1. Register resources with handlers
//! 2. Enable subscription support
//! 3. Handle subscription requests
//! 4. Notify subscribers of updates
//!
//! This is useful for servers that provide dynamic or changing resources
//! that clients want to be notified about.

const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create resource registry with subscription support
    var resources = mcp.primitives.ResourceRegistry.init(allocator);
    defer resources.deinit();

    // Enable subscription support
    resources.supports_subscriptions = true;

    // Register some example resources
    try resources.register(.{
        .uri = "config://app.json",
        .name = "Application Config",
        .description = "Main application configuration file",
        .mimeType = "application/json",
        .handler = configHandler,
    });

    try resources.register(.{
        .uri = "logs://latest.txt",
        .name = "Latest Logs",
        .description = "Most recent application logs",
        .mimeType = "text/plain",
        .handler = logsHandler,
    });

    try resources.register(.{
        .uri = "metrics://system.json",
        .name = "System Metrics",
        .description = "Real-time system metrics",
        .mimeType = "application/json",
        .handler = metricsHandler,
    });

    std.debug.print("Resource Subscription Example\n", .{});
    std.debug.print("=============================\n\n", .{});

    // Show resource count
    std.debug.print("Registered {d} resources\n\n", .{resources.count()});

    // Create subscription callback
    const update_callback = struct {
        fn onResourceUpdate(_: std.mem.Allocator, uri: []const u8) !void {
            std.debug.print("  [NOTIFICATION] Resource updated: {s}\n", .{uri});
        }
    }.onResourceUpdate;

    // Demonstrate subscription workflow
    std.debug.print("Subscription Workflow:\n", .{});
    std.debug.print("  1. Client subscribes to config://app.json\n", .{});

    try resources.subscribe("config://app.json", update_callback);
    std.debug.print("     ✓ Subscription successful\n", .{});

    std.debug.print("  2. Application detects config file change\n", .{});
    std.debug.print("  3. Server notifies subscriber\n", .{});

    try resources.notifyUpdate("config://app.json");

    std.debug.print("  4. Client checks subscription count\n", .{});
    const sub_count = resources.getSubscriptionCount("config://app.json");
    std.debug.print("     ✓ {d} active subscription(s)\n", .{sub_count});

    std.debug.print("  5. Client unsubscribes\n", .{});
    try resources.unsubscribe("config://app.json");
    std.debug.print("     ✓ Unsubscription successful\n", .{});

    const updated_count = resources.getSubscriptionCount("config://app.json");
    std.debug.print("     ✓ {d} active subscription(s) remaining\n", .{updated_count});

    std.debug.print("\n", .{});

    // Read resource content
    std.debug.print("Reading Resource Content:\n", .{});
    const content = try resources.read("config://app.json");
    std.debug.print("  URI: {s}\n", .{content.uri});
    if (content.text) |text| {
        std.debug.print("  Content: {s}\n", .{text});
    }

    std.debug.print("\nExample Complete!\n", .{});
}

/// Example handler for configuration resource
fn configHandler(allocator: std.mem.Allocator, uri: []const u8) !mcp.primitives.ResourceContent {
    _ = allocator; // For demonstration, we don't allocate
    const config =
        \\{
        \\  "version": "1.0.0",
        \\  "debug": true,
        \\  "port": 8080
        \\}
    ;

    return .{
        .uri = uri,
        .mimeType = "application/json",
        .text = config,
        .blob = null,
    };
}

/// Example handler for logs resource
fn logsHandler(allocator: std.mem.Allocator, uri: []const u8) !mcp.primitives.ResourceContent {
    _ = allocator; // For demonstration, we don't allocate
    const logs = "[2025-01-13T10:30:00Z] Application started\n[2025-01-13T10:30:15Z] Server listening on port 8080\n[2025-01-13T10:30:20Z] Ready to accept connections\n";

    return .{
        .uri = uri,
        .mimeType = "text/plain",
        .text = logs,
        .blob = null,
    };
}

/// Example handler for metrics resource
fn metricsHandler(allocator: std.mem.Allocator, uri: []const u8) !mcp.primitives.ResourceContent {
    _ = allocator; // For demonstration, we don't allocate
    const metrics =
        \\{
        \\  "cpu_usage": 45.2,
        \\  "memory_used_mb": 256,
        \\  "memory_total_mb": 2048,
        \\  "uptime_seconds": 3600,
        \\  "requests_served": 1250
        \\}
    ;

    return .{
        .uri = uri,
        .mimeType = "application/json",
        .text = metrics,
        .blob = null,
    };
}
