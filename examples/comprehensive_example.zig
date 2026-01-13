//! comprehensive_example.zig - Full-featured MCP server demonstrating all capabilities
//!
//! This example demonstrates:
//! - Tool registration with input schemas
//! - Proper lifecycle handling (initialize/shutdown)
//! - Multiple tool handlers with different signatures
//! - Error handling for invalid requests
//!
//! Run with: zig run examples/comprehensive_example.zig

const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== MCP Comprehensive Server ===\n", .{});
    std.debug.print("Starting full-featured MCP server...\n\n", .{});

    var server = try mcp.MCPServer.init(allocator);
    defer server.deinit();

    try registerTools(&server);
    std.debug.print("Tools registered: echo, get_server_info, calculate\n", .{});

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var initialized = false;
    var running = true;
    std.debug.print("Server ready. Waiting for MCP client connections...\n", .{});

    while (running) {
        const message = mcp.readContentLengthFrame(allocator, stdin) catch {
            break;
        };
        defer allocator.free(message);

        if (message.len == 0) continue;

        const response = processMessage(allocator, &server, message, &initialized, &running) catch |err| {
            std.debug.print("Error processing message: {any}\n", .{err});
            const error_resp = try createErrorResponse(allocator, null, -32603, "Internal error");
            defer allocator.free(error_resp);
            try mcp.writeContentLengthFrame(stdout, error_resp);
            continue;
        };
        defer allocator.free(response);

        if (response.len > 0) {
            try mcp.writeContentLengthFrame(stdout, response);
        }
    }

    std.debug.print("\nServer shutdown complete.\n", .{});
}

fn processMessage(allocator: std.mem.Allocator, server: *mcp.MCPServer, message: []const u8, initialized: *bool, running: *bool) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, message, .{}) catch {
        return try createErrorResponse(allocator, null, -32700, "Parse error");
    };
    defer parsed.deinit();

    const request = parsed.value;
    const method = request.object.get("method") orelse {
        return try createErrorResponse(allocator, null, -32600, "Method required");
    };
    const id = request.object.get("id");
    const params = request.object.get("params");

    if (method != .string) {
        return try createErrorResponse(allocator, null, -32600, "Method must be string");
    }
    const method_str = method.string;

    if (std.mem.eql(u8, method_str, "initialize")) {
        initialized.* = true;
        return try handleInitialize(allocator, id);
    }

    if (std.mem.eql(u8, method_str, "notifications/initialized")) {
        std.debug.print("Client initialized successfully.\n", .{});
        return try allocator.alloc(u8, 0);
    }

    if (!initialized.*) {
        return try createErrorResponse(allocator, id, -32000, "Server not initialized");
    }

    if (std.mem.eql(u8, method_str, "shutdown")) {
        std.debug.print("Shutdown requested.\n", .{});
        running.* = false;
        return try handleShutdown(allocator, id);
    }

    if (std.mem.eql(u8, method_str, "tools/list")) {
        return try handleToolsList(server, allocator, id);
    }

    if (std.mem.eql(u8, method_str, "tools/call")) {
        return try handleToolCall(server, allocator, params, id);
    }

    return try createErrorResponse(allocator, id, -32601, "Method not found");
}

fn registerTools(server: *mcp.MCPServer) !void {
    try server.registerTool(.{
        .name = "echo",
        .description = "Echoes back the input message",
        .handler = echoHandler,
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "message": {
        \\      "type": "string",
        \\      "description": "The message to echo back"
        \\    }
        \\  },
        \\  "required": ["message"]
        \\}
        ,
    });

    try server.registerTool(.{
        .name = "get_server_info",
        .description = "Returns server information",
        .handler = serverInfoHandler,
        .input_schema = null,
    });

    try server.registerTool(.{
        .name = "calculate",
        .description = "Perform basic arithmetic (add, subtract, multiply, divide)",
        .handler = calculateHandler,
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "operation": {
        \\      "type": "string",
        \\      "enum": ["add", "subtract", "multiply", "divide"],
        \\      "description": "Operation to perform"
        \\    },
        \\    "a": { "type": "number", "description": "First operand" },
        \\    "b": { "type": "number", "description": "Second operand" }
        \\  },
        \\  "required": ["operation", "a", "b"]
        \\}
        ,
    });
}

fn handleInitialize(allocator: std.mem.Allocator, id: ?std.json.Value) ![]const u8 {
    var capabilities = std.json.ObjectMap.init(allocator);
    var tools_capability = std.json.ObjectMap.init(allocator);
    try tools_capability.put("enabled", std.json.Value{ .bool = true });
    try capabilities.put("tools", std.json.Value{ .object = tools_capability });

    var server_info = std.json.ObjectMap.init(allocator);
    try server_info.put("name", std.json.Value{ .string = "comprehensive-mcp-server" });
    try server_info.put("version", std.json.Value{ .string = "1.0.0" });

    var result = std.json.ObjectMap.init(allocator);
    try result.put("protocolVersion", std.json.Value{ .string = mcp.PROTOCOL_VERSION });
    try result.put("capabilities", std.json.Value{ .object = capabilities });
    try result.put("serverInfo", std.json.Value{ .object = server_info });

    return try buildSuccessResponse(allocator, id, std.json.Value{ .object = result });
}

fn handleShutdown(allocator: std.mem.Allocator, id: ?std.json.Value) ![]const u8 {
    return try buildSuccessResponse(allocator, id, std.json.Value{ .null = {} });
}

fn handleToolsList(server: *mcp.MCPServer, allocator: std.mem.Allocator, id: ?std.json.Value) ![]const u8 {
    var tools_array = std.json.Array.init(allocator);

    var it = server.tools.iterator();
    while (it.next()) |entry| {
        const tool = entry.value_ptr.*;

        var tool_obj = std.json.ObjectMap.init(allocator);
        try tool_obj.put("name", std.json.Value{ .string = tool.name });
        try tool_obj.put("description", std.json.Value{ .string = tool.description });

        if (tool.input_schema) |schema| {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, schema, .{}) catch {
                var empty_schema = std.json.ObjectMap.init(allocator);
                try empty_schema.put("type", std.json.Value{ .string = "object" });
                try tool_obj.put("inputSchema", std.json.Value{ .object = empty_schema });
                try tools_array.append(std.json.Value{ .object = tool_obj });
                continue;
            };
            try tool_obj.put("inputSchema", parsed.value);
        } else {
            var empty_schema = std.json.ObjectMap.init(allocator);
            try empty_schema.put("type", std.json.Value{ .string = "object" });
            try tool_obj.put("inputSchema", std.json.Value{ .object = empty_schema });
        }

        try tools_array.append(std.json.Value{ .object = tool_obj });
    }

    var result = std.json.ObjectMap.init(allocator);
    try result.put("tools", std.json.Value{ .array = tools_array });

    return try buildSuccessResponse(allocator, id, std.json.Value{ .object = result });
}

fn handleToolCall(server: *mcp.MCPServer, allocator: std.mem.Allocator, params: ?std.json.Value, id: ?std.json.Value) ![]const u8 {
    const params_obj = params orelse {
        return try createErrorResponse(allocator, id, -32602, "Missing params");
    };
    if (params_obj != .object) {
        return try createErrorResponse(allocator, id, -32602, "Params must be object");
    }

    const tool_name = params_obj.object.get("name") orelse {
        return try createErrorResponse(allocator, id, -32602, "Missing tool name");
    };
    if (tool_name != .string) {
        return try createErrorResponse(allocator, id, -32602, "Tool name must be string");
    }

    const tool = server.tools.get(tool_name.string) orelse {
        return try createErrorResponse(allocator, id, -32601, "Tool not found");
    };

    const arguments = params_obj.object.get("arguments") orelse std.json.Value{ .null = {} };

    const result = tool.handler(allocator, arguments) catch {
        return try createErrorResponse(allocator, id, -32603, "Tool execution failed");
    };

    const result_text = switch (result) {
        .string => |s| s,
        else => blk: {
            var buf = std.ArrayList(u8).init(allocator);
            defer buf.deinit();
            try std.json.stringify(result, .{}, buf.writer());
            break :blk try buf.toOwnedSlice();
        },
    };

    var content_array = std.json.Array.init(allocator);
    var content_obj = std.json.ObjectMap.init(allocator);
    try content_obj.put("type", std.json.Value{ .string = "text" });
    try content_obj.put("text", std.json.Value{ .string = result_text });
    try content_array.append(std.json.Value{ .object = content_obj });

    var result_obj = std.json.ObjectMap.init(allocator);
    try result_obj.put("content", std.json.Value{ .array = content_array });

    return try buildSuccessResponse(allocator, id, std.json.Value{ .object = result_obj });
}

fn buildSuccessResponse(allocator: std.mem.Allocator, id: ?std.json.Value, result: std.json.Value) ![]const u8 {
    var response = std.json.ObjectMap.init(allocator);
    try response.put("jsonrpc", std.json.Value{ .string = "2.0" });
    try response.put("result", result);
    if (id) |id_val| {
        try response.put("id", id_val);
    }

    var buf = std.ArrayList(u8).init(allocator);
    try std.json.stringify(std.json.Value{ .object = response }, .{}, buf.writer());
    return try buf.toOwnedSlice();
}

fn createErrorResponse(allocator: std.mem.Allocator, id: ?std.json.Value, code: i32, message: []const u8) ![]const u8 {
    var error_obj = std.json.ObjectMap.init(allocator);
    try error_obj.put("code", std.json.Value{ .integer = code });
    try error_obj.put("message", std.json.Value{ .string = message });

    var response = std.json.ObjectMap.init(allocator);
    try response.put("jsonrpc", std.json.Value{ .string = "2.0" });
    try response.put("error", std.json.Value{ .object = error_obj });
    if (id) |id_val| {
        try response.put("id", id_val);
    }

    var buf = std.ArrayList(u8).init(allocator);
    try std.json.stringify(std.json.Value{ .object = response }, .{}, buf.writer());
    return try buf.toOwnedSlice();
}

fn echoHandler(_: std.mem.Allocator, params: std.json.Value) !std.json.Value {
    if (params != .object) return std.json.Value{ .string = "Error: Invalid params" };
    const msg = params.object.get("message") orelse return std.json.Value{ .string = "Error: message required" };
    if (msg != .string) return std.json.Value{ .string = "Error: message must be string" };
    return std.json.Value{ .string = msg.string };
}

fn serverInfoHandler(_: std.mem.Allocator, _: std.json.Value) !std.json.Value {
    var info = std.json.ObjectMap.init(std.heap.page_allocator);
    try info.put("name", std.json.Value{ .string = "comprehensive-mcp-server" });
    try info.put("version", std.json.Value{ .string = "1.0.0" });
    try info.put("description", std.json.Value{ .string = "Full-featured MCP server example" });
    return std.json.Value{ .object = info };
}

fn calculateHandler(_: std.mem.Allocator, params: std.json.Value) !std.json.Value {
    if (params != .object) return std.json.Value{ .string = "Error: Invalid params" };

    const op_val = params.object.get("operation") orelse return std.json.Value{ .string = "Error: operation required" };
    const a_val = params.object.get("a") orelse return std.json.Value{ .string = "Error: a required" };
    const b_val = params.object.get("b") orelse return std.json.Value{ .string = "Error: b required" };

    if (op_val != .string) return std.json.Value{ .string = "Error: operation must be string" };
    const op = op_val.string;

    const a = switch (a_val) {
        .integer => @as(f64, @floatFromInt(a_val.integer)),
        .float => a_val.float,
        else => return std.json.Value{ .string = "Error: a must be number" },
    };

    const b = switch (b_val) {
        .integer => @as(f64, @floatFromInt(b_val.integer)),
        .float => b_val.float,
        else => return std.json.Value{ .string = "Error: b must be number" },
    };

    const result = blk: {
        if (std.mem.eql(u8, op, "add")) {
            break :blk a + b;
        } else if (std.mem.eql(u8, op, "subtract")) {
            break :blk a - b;
        } else if (std.mem.eql(u8, op, "multiply")) {
            break :blk a * b;
        } else if (std.mem.eql(u8, op, "divide")) {
            if (b == 0) return std.json.Value{ .string = "Error: Division by zero" };
            break :blk a / b;
        } else {
            return std.json.Value{ .string = "Error: Unknown operation" };
        }
    };

    return std.json.Value{ .float = result };
}
