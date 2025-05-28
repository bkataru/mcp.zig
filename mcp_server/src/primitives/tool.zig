const std = @import("std");
const Prompt = @import("./prompt.zig").Prompt;
const Resource = @import("./resource.zig").Resource;

/// Function type for tool implementations
pub const ToolHandlerFn = *const fn (
    allocator: std.mem.Allocator,
    params: std.StringHashMap([]const u8),
) anyerror![]const u8;

/// Registry for managing and executing tools
pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(*Tool),

    /// Initialize a new tool registry
    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .tools = std.StringHashMap(*Tool).init(allocator),
        };
    }

    /// Register a new tool with the registry
    pub fn register(self: *@This(), tool: *Tool) !void {
        try self.tools.put(tool.name, tool);
    }

    /// Invoke a tool by name with given parameters
    pub fn invoke(
        self: *@This(),
        name: []const u8,
        params: std.StringHashMap([]const u8),
    ) ![]const u8 {
        if (self.tools.get(name)) |tool| {
            try tool.validateParams(params);
            return try tool.handler(self.allocator, params);
        } else {
            return error.ToolNotFound;
        }
    }

    /// Free registry resources
    pub fn deinit(self: *@This()) void {
        // Free all registered tools first
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            // Tool.deinit() now handles complete cleanup
            entry.value_ptr.*.deinit();
        }
        self.tools.deinit();
    }
};

/// Represents a tool that can process prompts and access resources
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.StringHashMap([]const u8),
    handler: ToolHandlerFn,
    allocator: std.mem.Allocator,

    /// Initialize a new tool with name, description and handler
    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        description: []const u8,
        handler: ToolHandlerFn,
    ) !*@This() {
        const tool = try allocator.create(@This());
        tool.* = .{
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, description),
            .parameters = std.StringHashMap([]const u8).init(allocator),
            .handler = handler,
            .allocator = allocator,
        };
        return tool;
    }

    /// Add a parameter to the tool
    pub fn addParameter(self: *@This(), name: []const u8, type_str: []const u8) !void {
        // Duplicate the strings to ensure they're owned by the tool
        const owned_name = try self.allocator.dupe(u8, name);
        const owned_type = try self.allocator.dupe(u8, type_str);
        try self.parameters.put(owned_name, owned_type);
    }

    /// Validate tool parameters against expected schema
    pub fn validateParams(self: *@This(), params: std.StringHashMap([]const u8)) !void {
        var it = self.parameters.iterator();
        while (it.next()) |entry| {
            const param_name = entry.key_ptr.*;
            const expected_type = entry.value_ptr.*;

            if (!params.contains(param_name)) {
                return error.MissingParameter;
            }

            const param_value = params.get(param_name).?;

            // Basic type validation
            if (std.mem.eql(u8, expected_type, "string")) {
                // All params are strings, just validate presence
            } else if (std.mem.eql(u8, expected_type, "number")) {
                _ = std.fmt.parseFloat(f64, param_value) catch {
                    return error.InvalidParameterType;
                };
            } else if (std.mem.eql(u8, expected_type, "boolean")) {
                if (!std.mem.eql(u8, param_value, "true") and
                    !std.mem.eql(u8, param_value, "false"))
                {
                    return error.InvalidParameterType;
                }
            }
        }
    }

    /// Free tool resources
    pub fn deinit(self: *@This()) void {
        // Free parameter keys and values
        var it = self.parameters.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.parameters.deinit();
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        self.allocator.destroy(self);
    }
};

test "Tool registration and invocation" {
    const allocator = std.testing.allocator;

    // Create a test tool
    const testHandler: ToolHandlerFn = struct {
        fn handler(
            allocator_: std.mem.Allocator,
            params: std.StringHashMap([]const u8),
        ) ![]const u8 {
            _ = allocator_;
            const value = params.get("test_param") orelse return error.MissingParameter;
            return value;
        }
    }.handler;

    var tool = try Tool.init(allocator, "test_tool", "Test tool", testHandler);
    defer tool.deinit();
    try tool.addParameter("test_param", "string");

    // Create registry and register tool
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();
    try registry.register(tool);

    // Test invocation
    var params = std.StringHashMap([]const u8).init(allocator);
    defer params.deinit();
    try params.put("test_param", "test_value");

    const result = try registry.invoke("test_tool", params);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("test_value", result);
}

test "Tool parameter validation" {
    const allocator = std.testing.allocator;

    const dummyHandler: ToolHandlerFn = struct {
        fn handler(
            allocator_: std.mem.Allocator,
            params: std.StringHashMap([]const u8),
        ) ![]const u8 {
            _ = allocator_;
            _ = params;
            return "";
        }
    }.handler;

    var tool = try Tool.init(allocator, "test_tool", "Test tool", dummyHandler);
    defer tool.deinit();
    try tool.addParameter("required", "string");
    try tool.addParameter("numeric", "number");
    try tool.addParameter("boolean", "boolean");

    // Test valid parameters
    var valid_params = std.StringHashMap([]const u8).init(allocator);
    defer valid_params.deinit();
    try valid_params.put("required", "value");
    try valid_params.put("numeric", "123");
    try valid_params.put("boolean", "true");
    try tool.validateParams(valid_params);

    // Test missing parameter
    var missing_params = std.StringHashMap([]const u8).init(allocator);
    defer missing_params.deinit();
    try missing_params.put("numeric", "123");
    try std.testing.expectError(error.MissingParameter, tool.validateParams(missing_params));

    // Test invalid type
    var invalid_params = std.StringHashMap([]const u8).init(allocator);
    defer invalid_params.deinit();
    try invalid_params.put("required", "value");
    try invalid_params.put("numeric", "not_a_number");
    try invalid_params.put("boolean", "true");
    try std.testing.expectError(error.InvalidParameterType, tool.validateParams(invalid_params));
}
