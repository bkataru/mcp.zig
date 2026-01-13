//! MCP Integration Test Script
//!
//! This script tests the MCP server with actual MCP protocol messages
//! to verify it works correctly with real MCP clients.

const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🧪 Starting MCP Integration Tests...\n", .{});

    // Test 1: Initialize request/response
    try testInitialize(allocator);

    // Test 2: Tools list request/response
    try testToolsList(allocator);

    // Test 3: Tool call request/response
    try testToolCall(allocator);

    std.debug.print("✅ All integration tests passed!\n", .{});
}

fn testInitialize(allocator: std.mem.Allocator) !void {
    std.debug.print("📋 Testing initialize request...\n", .{});

    // Create MCP server
    var server = try mcp.MCPServer.init(allocator);
    defer server.deinit();

    // Add a test tool
    try server.registerTool(.{
        .name = "test_tool",
        .description = "A test tool",
        .input_schema =
        \\{"type":"object","properties":{}}
        ,
        .handler = struct {
            fn handler(_: std.mem.Allocator, _: std.json.Value) !std.json.Value {
                return std.json.Value{ .string = "test result" };
            }
        }.handler,
    });

    // Test initialize request
    var init_request_map = std.json.ObjectMap.init(allocator);
    try init_request_map.put("jsonrpc", std.json.Value{ .string = "2.0" });
    try init_request_map.put("id", std.json.Value{ .integer = 1 });
    try init_request_map.put("method", std.json.Value{ .string = "initialize" });
    var init_params = std.json.ObjectMap.init(allocator);
    try init_request_map.put("params", std.json.Value{ .object = init_params });
    _ = &init_params;

    const init_request = std.json.Value{ .object = init_request_map };

    // Convert request to JSON string
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &out.writer,
    };
    try stringify.write(init_request);
    const request_json = try out.toOwnedSlice();
    defer allocator.free(request_json);

    // Simulate the initialize response
    const response = try server.handleRequest(request_json);
    defer allocator.free(response);

    // Verify response contains expected fields
    if (std.mem.indexOf(u8, response, "jsonrpc") == null) {
        return error.MissingJsonRpcField;
    }
    if (std.mem.indexOf(u8, response, "protocolVersion") == null) {
        return error.MissingProtocolVersion;
    }
    if (std.mem.indexOf(u8, response, "capabilities") == null) {
        return error.MissingCapabilities;
    }

    std.debug.print("✅ Initialize test passed\n", .{});
}

fn testToolsList(allocator: std.mem.Allocator) !void {
    std.debug.print("🔧 Testing tools/list request...\n", .{});

    // Create MCP server
    var server = try mcp.MCPServer.init(allocator);
    defer server.deinit();

    // Add tools
    try server.registerTool(.{
        .name = "calculator",
        .description = "Calculator tool",
        .input_schema =
        \\{"type":"object","properties":{"expression":{"type":"string"}}}
        ,
        .handler = struct {
            fn handler(_: std.mem.Allocator, _: std.json.Value) !std.json.Value {
                return std.json.Value{ .string = "42" };
            }
        }.handler,
    });

    try server.registerTool(.{
        .name = "cli",
        .description = "CLI tool",
        .input_schema =
        \\{"type":"object","properties":{"command":{"type":"string"}}}
        ,
        .handler = struct {
            fn handler(_: std.mem.Allocator, _: std.json.Value) !std.json.Value {
                return std.json.Value{ .string = "executed" };
            }
        }.handler,
    });

    try server.registerTool(.{
        .name = "cli",
        .description = "CLI tool",
        .input_schema =
        \\{"type":"object","properties":{"command":{"type":"string"}}}
        ,
        .handler = struct {
            fn handler(_: std.mem.Allocator, _: std.json.Value) !std.json.Value {
                return std.json.Value{ .string = "executed" };
            }
        }.handler,
    });

    // Test tools/list request
    var list_request_map = std.json.ObjectMap.init(allocator);
    try list_request_map.put("jsonrpc", std.json.Value{ .string = "2.0" });
    try list_request_map.put("id", std.json.Value{ .integer = 2 });
    try list_request_map.put("method", std.json.Value{ .string = "tools/list" });
    var list_params = std.json.ObjectMap.init(allocator);
    try list_request_map.put("params", std.json.Value{ .object = list_params });
    _ = &list_params;

    const list_request = std.json.Value{ .object = list_request_map };

    // Convert request to JSON string
    var list_out: std.io.Writer.Allocating = .init(allocator);
    defer list_out.deinit();
    var list_stringify: std.json.Stringify = .{
        .writer = &list_out.writer,
    };
    try list_stringify.write(list_request);
    const list_request_json = try list_out.toOwnedSlice();
    defer allocator.free(list_request_json);

    // Simulate the tools/list response
    const response = try server.handleRequest(list_request_json);
    defer allocator.free(response);

    // Verify response contains tools
    if (std.mem.indexOf(u8, response, "calculator") == null) {
        return error.MissingCalculatorTool;
    }
    if (std.mem.indexOf(u8, response, "cli") == null) {
        return error.MissingCliTool;
    }

    std.debug.print("✅ Tools list test passed\n", .{});
}

fn testToolCall(allocator: std.mem.Allocator) !void {
    std.debug.print("⚡ Testing tools/call request...\n", .{});

    // Create MCP server
    var server = try mcp.MCPServer.init(allocator);
    defer server.deinit();

    // Add calculator tool
    try server.registerTool(.{
        .name = "add",
        .description = "Add two numbers",
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "a": { "type": "number" },
        \\    "b": { "type": "number" }
        \\  },
        \\  "required": ["a", "b"]
        \\}
        ,
        .handler = struct {
            fn handler(_: std.mem.Allocator, arguments: std.json.Value) !std.json.Value {
                const a = arguments.object.get("a").?.float;
                const b = arguments.object.get("b").?.float;
                const result = a + b;
                return std.json.Value{ .float = result };
            }
        }.handler,
    });

    // Test tool call request
    var call_request_map = std.json.ObjectMap.init(allocator);
    try call_request_map.put("jsonrpc", std.json.Value{ .string = "2.0" });
    try call_request_map.put("id", std.json.Value{ .integer = 3 });
    try call_request_map.put("method", std.json.Value{ .string = "tools/call" });

    var call_params = std.json.ObjectMap.init(allocator);
    try call_params.put("name", std.json.Value{ .string = "add" });

    var args = std.json.ObjectMap.init(allocator);
    try args.put("a", std.json.Value{ .float = 10 });
    try args.put("b", std.json.Value{ .float = 20 });
    try call_params.put("arguments", std.json.Value{ .object = args });

    try call_request_map.put("params", std.json.Value{ .object = call_params });

    const call_request = std.json.Value{ .object = call_request_map };

    // Convert request to JSON string
    var call_out: std.io.Writer.Allocating = .init(allocator);
    defer call_out.deinit();
    var call_stringify: std.json.Stringify = .{
        .writer = &call_out.writer,
    };
    try call_stringify.write(call_request);
    const call_request_json = try call_out.toOwnedSlice();
    defer allocator.free(call_request_json);

    // Simulate the tool call response
    const response = try server.handleRequest(call_request_json);
    defer allocator.free(response);

    // Verify response contains result (should be 30)
    if (std.mem.indexOf(u8, response, "30") == null) {
        return error.IncorrectCalculationResult;
    }

    std.debug.print("✅ Tool call test passed (10 + 20 = 30)\n", .{});
}
