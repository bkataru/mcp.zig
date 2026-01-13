//! MCP Sampling Example
//!
//! This example demonstrates how to implement server-initiated LLM sampling.
//! The server can request text completions from the MCP client (which has LLM access).
//!
//! Note: This requires an MCP client that supports sampling (currently limited).

const std = @import("std");
const mcp = @import("mcp");

/// Example sampling handler that simulates LLM completion
fn samplingHandler(allocator: std.mem.Allocator, request: mcp.types.CreateMessageRequest) !mcp.types.CreateMessageResult {
    std.debug.print("🎯 Received sampling request with {d} messages\n", .{request.messages.len});

    // Log the request details
    for (request.messages, 0..) |msg, i| {
        std.debug.print("  Message {d}: {s} - ", .{ i + 1, msg.role });
        switch (msg.content) {
            .text => |text| std.debug.print("'{s}'\n", .{text.text}),
            else => std.debug.print("[non-text content]\n", .{}),
        }
    }

    if (request.systemPrompt) |prompt| {
        std.debug.print("  System prompt: '{s}'\n", .{prompt});
    }

    if (request.temperature) |temp| {
        std.debug.print("  Temperature: {d}\n", .{temp});
    }

    if (request.maxTokens) |max| {
        std.debug.print("  Max tokens: {d}\n", .{max});
    }

    // Simulate LLM completion (in real implementation, this would call an LLM API)
    const completion_text = try std.fmt.allocPrint(allocator,
        \\Based on the context provided, here's a thoughtful response that demonstrates
        \\the sampling capability. The server successfully requested LLM completion
        \\from the client, showing how MCP enables servers to leverage client-side AI.
    , .{});

    return mcp.types.CreateMessageResult{
        .role = "assistant",
        .content = .{ .text = .{ .text = completion_text } },
        .model = "example-llm-model",
        .stopReason = "end_turn",
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🧠 MCP Sampling Server Example\n", .{});
    std.debug.print("This demonstrates server-initiated LLM sampling capability.\n\n", .{});

    // Create MCP server
    var server = try mcp.MCPServer.init(allocator);
    defer server.deinit();

    // Register sampling handler
    server.setSamplingHandler(samplingHandler);
    std.debug.print("✅ Registered sampling handler\n", .{});

    // Add a tool that might use sampling internally
    try server.registerTool(.{
        .name = "analyze_text",
        .description = "Analyze text using LLM sampling",
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "text": { "type": "string", "description": "Text to analyze" },
        \\    "analysis_type": {
        \\      "type": "string",
        \\      "enum": ["summary", "sentiment", "keywords"],
        \\      "description": "Type of analysis to perform"
        \\    }
        \\  },
        \\  "required": ["text", "analysis_type"]
        \\}
        ,
        .handler = struct {
            fn handler(alloc: std.mem.Allocator, args: std.json.Value) !std.json.Value {
                const text = args.object.get("text").?.string;
                const analysis_type = args.object.get("analysis_type").?.string;

                // In a real implementation, this tool could use sampling to analyze text
                const result = try std.fmt.allocPrint(alloc, "Analysis complete: {s} analysis of '{s}' performed using LLM sampling.", .{ analysis_type, text });

                return std.json.Value{ .string = result };
            }
        }.handler,
    });
    std.debug.print("✅ Registered analysis tool\n", .{});

    std.debug.print("\n🚀 Server Capabilities:\n", .{});
    std.debug.print("   • Tools: enabled\n", .{});
    std.debug.print("   • Sampling: {s}\n", .{if (server.sampling_handler != null) "enabled" else "disabled"});

    std.debug.print("\n💡 To test sampling:\n", .{});
    std.debug.print("   1. Connect with an MCP client that supports sampling\n", .{});
    std.debug.print("   2. Send a sampling/createMessage request\n", .{});
    std.debug.print("   3. The server will respond with simulated LLM completion\n", .{});

    std.debug.print("\n🔄 Starting server (would listen for connections in real implementation)\n", .{});

    // In a real server, this would start accepting connections
    // For this demo, we'll just show the capabilities

    std.debug.print("🎉 Sampling example completed successfully!\n", .{});
}
