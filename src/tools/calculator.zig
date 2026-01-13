const std = @import("std");

/// Calculator tool handler - enhanced for MCP 2024-11-05 protocol
/// Handles basic arithmetic operations with improved error handling
pub fn calculatorHandler(allocator: std.mem.Allocator, params: std.json.Value) anyerror!std.json.Value {
    if (params != .object) {
        return error.InvalidParams;
    }

    const operation = params.object.get("operation") orelse return error.MissingOperation;
    const a_param = params.object.get("a") orelse return error.MissingParameterA;
    const b_param = params.object.get("b") orelse return error.MissingParameterB;

    if (operation != .string) return error.InvalidOperationType;

    const a = switch (a_param) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        .string => |s| std.fmt.parseFloat(f64, s) catch return error.InvalidParameterA,
        else => return error.InvalidParameterA,
    };

    const b = switch (b_param) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        .string => |s| std.fmt.parseFloat(f64, s) catch return error.InvalidParameterB,
        else => return error.InvalidParameterB,
    };

    const result = if (std.mem.eql(u8, operation.string, "add"))
        a + b
    else if (std.mem.eql(u8, operation.string, "subtract"))
        a - b
    else if (std.mem.eql(u8, operation.string, "multiply"))
        a * b
    else if (std.mem.eql(u8, operation.string, "divide")) blk: {
        if (b == 0) return error.DivisionByZero;
        break :blk a / b;
    } else return error.InvalidOperation;

    const result_str = try std.fmt.allocPrint(allocator, "{d}", .{result});
    return std.json.Value{ .string = result_str };
}

/// Calculator tool input schema - follows JSON Schema specification
pub const calculator_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "operation": {
    \\      "type": "string",
    \\      "enum": ["add", "subtract", "multiply", "divide"],
    \\      "description": "The arithmetic operation to perform"
    \\    },
    \\    "a": {
    \\      "type": "number",
    \\      "description": "The first number"
    \\    },
    \\    "b": {
    \\      "type": "number", 
    \\      "description": "The second number"
    \\    }
    \\  },
    \\  "required": ["operation", "a", "b"]
    \\}
;

// Legacy compatibility
const tool = @import("../primitives/tool.zig");
const Tool = tool.Tool;

/// Calculator tool handler function - legacy compatibility
fn calculatorHandlerLegacy(
    allocator: std.mem.Allocator,
    params: std.StringHashMap([]const u8),
) anyerror![]const u8 {
    const operation = params.get("operation") orelse return error.MissingParameter;
    const a_str = params.get("a") orelse return error.MissingParameter;
    const b_str = params.get("b") orelse return error.MissingParameter;

    const a = std.fmt.parseFloat(f64, a_str) catch return error.InvalidParameterType;
    const b = std.fmt.parseFloat(f64, b_str) catch return error.InvalidParameterType;

    const result = if (std.mem.eql(u8, operation, "add"))
        a + b
    else if (std.mem.eql(u8, operation, "subtract"))
        a - b
    else if (std.mem.eql(u8, operation, "multiply"))
        a * b
    else if (std.mem.eql(u8, operation, "divide")) blk: {
        if (b == 0) return error.DivisionByZero;
        break :blk a / b;
    } else return error.InvalidOperation;

    return std.fmt.allocPrint(allocator, "{d}", .{result});
}

pub const Calculator = struct {
    tool_instance: *Tool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Calculator {
        const tool_instance = try Tool.init(allocator, "calculator", "Basic arithmetic operations", calculatorHandlerLegacy);

        try tool_instance.addParameter("operation", "string");
        try tool_instance.addParameter("a", "number");
        try tool_instance.addParameter("b", "number");

        return Calculator{
            .tool_instance = tool_instance,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Calculator) void {
        self.tool_instance.parameters.deinit();
        self.allocator.free(self.tool_instance.name);
        self.allocator.free(self.tool_instance.description);
        self.allocator.destroy(self.tool_instance);
    }
};

// Export the legacy init function for compatibility
pub fn init(allocator: std.mem.Allocator) !*Tool {
    const calc = try Calculator.init(allocator);
    return calc.tool_instance;
}
