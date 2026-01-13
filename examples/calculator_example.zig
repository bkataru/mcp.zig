//! calculator_example.zig - MCP server with calculator tools
//!
//! This example demonstrates:
//! - Tools with complex input schemas
//! - Parameter validation and error handling
//! - Multiple arithmetic operations
//!
//! Run with: zig run examples/calculator_example.zig

const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== MCP Calculator Server ===\n", .{});
    std.debug.print("Starting MCP server with calculator tools...\n\n", .{});

    var server = try mcp.MCPServer.init(allocator);
    defer server.deinit();

    try server.registerTool(.{
        .name = "add",
        .description = "Add two numbers together",
        .handler = addHandler,
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "a": { "type": "number", "description": "First number" },
        \\    "b": { "type": "number", "description": "Second number" }
        \\  },
        \\  "required": ["a", "b"]
        \\}
        ,
    });

    try server.registerTool(.{
        .name = "subtract",
        .description = "Subtract b from a",
        .handler = subtractHandler,
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "a": { "type": "number", "description": "First number" },
        \\    "b": { "type": "number", "description": "Number to subtract" }
        \\  },
        \\  "required": ["a", "b"]
        \\}
        ,
    });

    try server.registerTool(.{
        .name = "multiply",
        .description = "Multiply two numbers",
        .handler = multiplyHandler,
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "a": { "type": "number", "description": "First number" },
        \\    "b": { "type": "number", "description": "Second number" }
        \\  },
        \\  "required": ["a", "b"]
        \\}
        ,
    });

    try server.registerTool(.{
        .name = "divide",
        .description = "Divide a by b (returns error if dividing by zero)",
        .handler = divideHandler,
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "a": { "type": "number", "description": "Dividend" },
        \\    "b": { "type": "number", "description": "Divisor (must not be zero)" }
        \\  },
        \\  "required": ["a", "b"]
        \\}
        ,
    });

    try server.registerTool(.{
        .name = "power",
        .description = "Raise a to the power of b",
        .handler = powerHandler,
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "base": { "type": "number", "description": "Base number" },
        \\    "exponent": { "type": "number", "description": "Exponent" }
        \\  },
        \\  "required": ["base", "exponent"]
        \\}
        ,
    });

    try server.registerTool(.{
        .name = "sqrt",
        .description = "Calculate the square root of a number",
        .handler = sqrtHandler,
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "value": { "type": "number", "description": "Number to calculate square root of" }
        \\  },
        \\  "required": ["value"]
        \\}
        ,
    });

    std.debug.print("Registered tools: add, subtract, multiply, divide, power, sqrt\n", .{});
    std.debug.print("Server is ready. Waiting for MCP client connections...\n", .{});

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    while (true) {
        const message = try mcp.readContentLengthFrame(allocator, stdin) catch {
            break;
        };
        defer allocator.free(message);

        if (message.len == 0) continue;

        const response = try server.handleRequest(message);
        defer allocator.free(response);

        if (response.len > 0) {
            try mcp.writeContentLengthFrame(stdout, response);
        }
    }
}

fn getNumber(params: std.json.Value, key: []const u8) !f64 {
    if (params != .object) return error.InvalidParams;

    const value = params.object.get(key) orelse {
        return error.MissingParameter;
    };

    return switch (value) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        .string => std.fmt.parseFloat(f64, value.string) catch {
            return error.InvalidParameterType;
        },
        else => error.InvalidParameterType,
    };
}

fn addHandler(_: std.mem.Allocator, params: std.json.Value) !std.json.Value {
    const a = try getNumber(params, "a");
    const b = try getNumber(params, "b");
    const result = a + b;
    return std.json.Value{ .float = result };
}

fn subtractHandler(_: std.mem.Allocator, params: std.json.Value) !std.json.Value {
    const a = try getNumber(params, "a");
    const b = try getNumber(params, "b");
    const result = a - b;
    return std.json.Value{ .float = result };
}

fn multiplyHandler(_: std.mem.Allocator, params: std.json.Value) !std.json.Value {
    const a = try getNumber(params, "a");
    const b = try getNumber(params, "b");
    const result = a * b;
    return std.json.Value{ .float = result };
}

fn divideHandler(_: std.mem.Allocator, params: std.json.Value) !std.json.Value {
    const a = try getNumber(params, "a");
    const b = try getNumber(params, "b");

    if (b == 0.0) {
        return std.json.Value{ .string = "Error: Division by zero" };
    }

    const result = a / b;
    return std.json.Value{ .float = result };
}

fn powerHandler(_: std.mem.Allocator, params: std.json.Value) !std.json.Value {
    const base = try getNumber(params, "base");
    const exponent = try getNumber(params, "exponent");
    const result = std.math.pow(f64, base, exponent);
    return std.json.Value{ .float = result };
}

fn sqrtHandler(_: std.mem.Allocator, params: std.json.Value) !std.json.Value {
    const value = try getNumber(params, "value");

    if (value < 0) {
        return std.json.Value{ .string = "Error: Cannot calculate square root of negative number" };
    }

    const result = @sqrt(value);
    return std.json.Value{ .float = result };
}
