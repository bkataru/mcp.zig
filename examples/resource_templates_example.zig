//! Resource Templates Example
//!
//! This example demonstrates how to use resource templates in MCP.
//! Resource templates allow you to define patterns for dynamically
//! generated resources with parameterized URIs.

const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("📋 MCP Resource Templates Demo\n\n", .{});

    var server = try mcp.MCPServer.init(allocator);
    defer server.deinit();

    std.debug.print("Creating resource templates...\n\n", .{});

    const templates = [_]mcp.types.ResourceTemplate{
        .{
            .uriTemplate = "file:///{path}",
            .name = "File Access",
            .description = "Access files by path",
            .mimeType = "text/plain",
        },
        .{
            .uriTemplate = "logs://{level}/{date}",
            .name = "Log Viewer",
            .description = "View logs by level and date",
            .mimeType = "text/plain",
        },
        .{
            .uriTemplate = "config://{section}/{key}",
            .name = "Config Reader",
            .description = "Read configuration values",
            .mimeType = "application/json",
        },
    };

    std.debug.print("📁 Templates defined:\n", .{});
    for (templates, 0..) |template, i| {
        std.debug.print("   {d}. {s}: {s}\n", .{ i + 1, template.name, template.uriTemplate });
        if (template.description) |desc| {
            std.debug.print("      Description: {s}\n", .{desc});
        }
        if (template.mimeType) |mime| {
            std.debug.print("      MIME Type: {s}\n", .{mime});
        }
    }

    std.debug.print("\n🔍 Simulating resource resolution:\n", .{});

    const resources = [_]mcp.types.Resource{
        .{
            .uri = "file:///home/user/config.json",
            .name = "Config File",
            .description = "User configuration file",
            .mimeType = "application/json",
        },
        .{
            .uri = "logs://error/2024-01-13",
            .name = "Error Logs",
            .description = "Error logs for today",
            .mimeType = "text/plain",
        },
    };

    std.debug.print("\n📊 Resolved resources:\n", .{});
    for (resources, 0..) |resource, i| {
        std.debug.print("   {d}. {s}\n", .{ i + 1, resource.name });
        std.debug.print("      URI: {s}\n", .{resource.uri});
        if (resource.mimeType) |mime| {
            std.debug.print("      MIME: {s}\n", .{mime});
        }
        if (resource.description) |desc| {
            std.debug.print("      Description: {s}\n", .{desc});
        }
    }

    std.debug.print("\n💡 Use Cases for Resource Templates:\n", .{});
    std.debug.print("   • File systems with dynamic paths\n", .{});
    std.debug.print("   • Log viewers with date/time parameters\n", .{});
    std.debug.print("   • Config sections with nested keys\n", .{});
    std.debug.print("   • Database records with IDs\n", .{});
    std.debug.print("   • API endpoints with query parameters\n", .{});

    std.debug.print("\n🎯 Template Features:\n", .{});
    std.debug.print("   • Pattern matching for URI resolution\n", .{});
    std.debug.print("   • Type-safe parameter extraction\n", .{});
    std.debug.print("   • Automatic documentation generation\n", .{});
    std.debug.print("   • Consistent MIME type handling\n", .{});

    std.debug.print("\n✅ Resource templates demo completed!\n", .{});
}
