const std = @import("std");
const tool = @import("../primitives/tool.zig");
const Tool = tool.Tool;

/// Calculator tool handler function
fn calculatorHandler(
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
        const tool_instance = try Tool.init(allocator, "calculator", "Basic arithmetic operations", calculatorHandler);

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

    pub fn tool(self: *Calculator) !Calculator {
        return Calculator{
            .tool_instance = self.tool_instance,
            .allocator = self.allocator,
        };
    }
};

/// Initialize calculator tool for compatibility with existing code
pub fn init(allocator: std.mem.Allocator) !*Tool {
    const tool_instance = try Tool.init(allocator, "calculator", "Basic arithmetic operations", calculatorHandler);

    try tool_instance.addParameter("operation", "string");
    try tool_instance.addParameter("a", "number");
    try tool_instance.addParameter("b", "number");

    return tool_instance;
}
