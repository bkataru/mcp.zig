const std = @import("std");
const builtin = @import("builtin");
const tool = @import("primitives/tool.zig");
const Tool = tool.Tool;
const Resource = @import("primitives/resource.zig");
const jsonrpc = @import("jsonrpc.zig");
const network = @import("network.zig");

/// MCP Protocol version - aligned with latest specification
pub const PROTOCOL_VERSION = "2024-11-05";

/// MCP Server state
pub const ServerState = enum {
    created,
    initializing,
    ready,
    error_state,
    shutdown,
};

/// Tool handler function signature - matches reference implementations
pub const ToolHandler = *const fn (allocator: std.mem.Allocator, params: std.json.Value) anyerror!std.json.Value;

/// MCP Tool definition - simplified from reference patterns
pub const MCPTool = struct {
    name: []const u8,
    description: []const u8,
    handler: ToolHandler,
    input_schema: ?[]const u8 = null,
};

/// Enhanced MCP Server implementation
/// Incorporates arena allocator patterns and improved error handling from zig-mcp-server reference
pub const MCPServer = struct {
    parent_allocator: std.mem.Allocator,
    state: ServerState,
    tools: std.StringHashMap(MCPTool),
    request_context: ?*std.heap.ArenaAllocator = null,

    /// Initialize a new MCP server instance
    pub fn init(allocator: std.mem.Allocator) !@This() {
        const tools = std.StringHashMap(MCPTool).init(allocator);

        return .{
            .parent_allocator = allocator,
            .state = .created,
            .tools = tools,
        };
    }

    /// Register a tool with the server
    pub fn registerTool(self: *@This(), tool_def: MCPTool) !void {
        // Validate tool definition
        if (tool_def.name.len == 0) return error.InvalidToolName;
        if (tool_def.description.len == 0) return error.InvalidToolDescription;

        // Create a persistent copy of the tool definition
        const persistent_name = try self.parent_allocator.dupe(u8, tool_def.name);
        const persistent_description = try self.parent_allocator.dupe(u8, tool_def.description);

        var persistent_tool = tool_def;
        persistent_tool.name = persistent_name;
        persistent_tool.description = persistent_description;

        if (tool_def.input_schema) |schema| {
            persistent_tool.input_schema = try self.parent_allocator.dupe(u8, schema);
        }

        try self.tools.put(persistent_name, persistent_tool);
        std.log.debug("Registered tool: {s}", .{tool_def.name});
    }

    /// Handle an MCP protocol request with arena allocator pattern
    pub fn handleRequest(self: *@This(), request_str: []const u8) ![]const u8 {
        // Create arena allocator for this request-response cycle
        var arena_allocator = std.heap.ArenaAllocator.init(self.parent_allocator);
        defer arena_allocator.deinit();
        self.request_context = &arena_allocator;
        const arena = arena_allocator.allocator();

        // Parse the JSON-RPC request
        const request = std.json.parseFromSlice(std.json.Value, arena, request_str, .{}) catch {
            const error_response = try self.createErrorResponse(arena, null, .parseError, "Invalid JSON");
            return try self.stringifyResponse(error_response);
        };

        if (request.value != .object) {
            const error_response = try self.createErrorResponse(arena, null, .invalidRequest, "Request must be an object");
            return try self.stringifyResponse(error_response);
        }

        const method = request.value.object.get("method") orelse {
            const error_response = try self.createErrorResponse(arena, null, .invalidRequest, "Method field missing");
            return try self.stringifyResponse(error_response);
        };

        if (method != .string) {
            const error_response = try self.createErrorResponse(arena, null, .invalidRequest, "Method must be a string");
            return try self.stringifyResponse(error_response);
        }

        const params = request.value.object.get("params") orelse std.json.Value{ .object = std.json.ObjectMap.init(arena) };
        const id = request.value.object.get("id");

        // Handle MCP protocol methods
        if (std.mem.eql(u8, method.string, "initialize")) {
            return try self.handleInitialize(arena, request.value);
        } else if (std.mem.eql(u8, method.string, "initialized")) {
            // Notification - no response needed
            return try self.parent_allocator.dupe(u8, "");
        } else if (std.mem.eql(u8, method.string, "shutdown")) {
            self.state = .shutdown;
            const response = try self.createSuccessResponse(arena, id, std.json.Value{ .null = {} });
            return try self.stringifyResponse(response);
        } else if (std.mem.eql(u8, method.string, "tools/list")) {
            return try self.handleToolsList(arena, id);
        } else if (std.mem.eql(u8, method.string, "tools/call")) {
            return try self.handleToolCall(arena, params, id);
        }

        // Method not found
        const error_response = try self.createErrorResponse(arena, id, .methodNotFound, "Method not found");
        return try self.stringifyResponse(error_response);
    }

    /// Handle initialize request - establishes MCP session
    fn handleInitialize(self: *@This(), arena: std.mem.Allocator, request: std.json.Value) ![]const u8 {
        self.state = .initializing;

        // Extract client capabilities from params
        const params = request.object.get("params") orelse {
            const error_response = try self.createErrorResponse(arena, request.object.get("id"), .invalidParams, "Params missing in initialize request");
            return try self.stringifyResponse(error_response);
        };

        // Validate protocol version if provided
        if (params.object.get("protocolVersion")) |version| {
            if (version != .string or !std.mem.eql(u8, version.string, PROTOCOL_VERSION)) {
                const error_response = try self.createErrorResponse(arena, request.object.get("id"), .unknownProtocolVersion, "Unsupported protocol version");
                return try self.stringifyResponse(error_response);
            }
        }

        // Create server capabilities
        var capabilities = std.json.Value{ .object = std.json.ObjectMap.init(arena) };
        try capabilities.object.put("protocolVersion", std.json.Value{ .string = try arena.dupe(u8, PROTOCOL_VERSION) });

        // Add tools capability
        var tools_capability = std.json.Value{ .object = std.json.ObjectMap.init(arena) };
        try tools_capability.object.put("enabled", std.json.Value{ .bool = true });
        try capabilities.object.put("tools", tools_capability);

        // Create server info
        var server_info = std.json.Value{ .object = std.json.ObjectMap.init(arena) };
        try server_info.object.put("name", std.json.Value{ .string = "mcp-zig-server" });
        try server_info.object.put("version", std.json.Value{ .string = "1.0.0" });

        // Create response
        var result = std.json.Value{ .object = std.json.ObjectMap.init(arena) };
        try result.object.put("capabilities", capabilities);
        try result.object.put("serverInfo", server_info);

        self.state = .ready;

        const response = try self.createSuccessResponse(arena, request.object.get("id"), result);
        return try self.stringifyResponse(response);
    }

    /// Handle tools/list request - returns available tools
    fn handleToolsList(self: *@This(), arena: std.mem.Allocator, id: ?std.json.Value) ![]const u8 {
        if (self.state != .ready) {
            const error_response = try self.createErrorResponse(arena, id, .serverNotInitialized, "Server not initialized");
            return try self.stringifyResponse(error_response);
        }

        var tools_array = std.json.Array.init(arena);

        var tool_iter = self.tools.iterator();
        while (tool_iter.next()) |entry| {
            const tool_def = entry.value_ptr.*;

            var tool_obj = std.json.Value{ .object = std.json.ObjectMap.init(arena) };
            try tool_obj.object.put("name", std.json.Value{ .string = try arena.dupe(u8, tool_def.name) });
            try tool_obj.object.put("description", std.json.Value{ .string = try arena.dupe(u8, tool_def.description) });

            if (tool_def.input_schema) |schema| {
                try tool_obj.object.put("inputSchema", std.json.Value{ .string = try arena.dupe(u8, schema) });
            }

            try tools_array.append(tool_obj);
        }

        var result = std.json.Value{ .object = std.json.ObjectMap.init(arena) };
        try result.object.put("tools", std.json.Value{ .array = tools_array });

        const response = try self.createSuccessResponse(arena, id, result);
        return try self.stringifyResponse(response);
    }

    /// Handle tools/call request - executes a tool
    fn handleToolCall(self: *@This(), arena: std.mem.Allocator, params: std.json.Value, id: ?std.json.Value) ![]const u8 {
        if (self.state != .ready) {
            const error_response = try self.createErrorResponse(arena, id, .serverNotInitialized, "Server not initialized");
            return try self.stringifyResponse(error_response);
        }

        if (params != .object) {
            const error_response = try self.createErrorResponse(arena, id, .invalidParams, "Params must be an object");
            return try self.stringifyResponse(error_response);
        }

        const tool_name = params.object.get("name") orelse {
            const error_response = try self.createErrorResponse(arena, id, .invalidParams, "Tool name missing");
            return try self.stringifyResponse(error_response);
        };

        if (tool_name != .string) {
            const error_response = try self.createErrorResponse(arena, id, .invalidParams, "Tool name must be a string");
            return try self.stringifyResponse(error_response);
        }

        const tool_def = self.tools.get(tool_name.string) orelse {
            const error_response = try self.createErrorResponse(arena, id, .unknownTool, "Tool not found");
            return try self.stringifyResponse(error_response);
        };

        const tool_params = params.object.get("arguments") orelse std.json.Value{ .object = std.json.ObjectMap.init(arena) };

        // Execute the tool
        const tool_result = tool_def.handler(arena, tool_params) catch |err| {
            const error_msg = std.fmt.allocPrint(arena, "Tool execution failed: {any}", .{err}) catch "Tool execution failed";
            const error_response = try self.createErrorResponse(arena, id, .internalError, error_msg);
            return try self.stringifyResponse(error_response);
        };

        // Create response with tool result
        var content_array = std.json.Array.init(arena);
        var content_obj = std.json.Value{ .object = std.json.ObjectMap.init(arena) };
        try content_obj.object.put("type", std.json.Value{ .string = "text" });

        // Convert tool result to text if needed
        const text_result = switch (tool_result) {
            .string => |s| s,
            else => blk: {
                var result_str = std.ArrayList(u8).init(arena);
                try std.json.stringify(tool_result, .{}, result_str.writer());
                break :blk try result_str.toOwnedSlice();
            },
        };

        try content_obj.object.put("text", std.json.Value{ .string = text_result });
        try content_array.append(content_obj);

        var result = std.json.Value{ .object = std.json.ObjectMap.init(arena) };
        try result.object.put("content", std.json.Value{ .array = content_array });

        const response = try self.createSuccessResponse(arena, id, result);
        return try self.stringifyResponse(response);
    }

    /// Create a JSON-RPC success response
    fn createSuccessResponse(self: *@This(), arena: std.mem.Allocator, id: ?std.json.Value, result: std.json.Value) !std.json.Value {
        _ = self;
        var response = std.json.Value{ .object = std.json.ObjectMap.init(arena) };
        try response.object.put("jsonrpc", std.json.Value{ .string = "2.0" });
        try response.object.put("result", result);

        if (id) |id_val| {
            try response.object.put("id", id_val);
        }

        return response;
    }

    /// Create a JSON-RPC error response
    fn createErrorResponse(self: *@This(), arena: std.mem.Allocator, id: ?std.json.Value, error_code: ErrorCode, message: []const u8) !std.json.Value {
        _ = self;
        var error_obj = std.json.Value{ .object = std.json.ObjectMap.init(arena) };
        try error_obj.object.put("code", std.json.Value{ .integer = @intFromEnum(error_code) });
        try error_obj.object.put("message", std.json.Value{ .string = try arena.dupe(u8, message) });

        var response = std.json.Value{ .object = std.json.ObjectMap.init(arena) };
        try response.object.put("jsonrpc", std.json.Value{ .string = "2.0" });
        try response.object.put("error", error_obj);

        if (id) |id_val| {
            try response.object.put("id", id_val);
        }

        return response;
    }

    /// Convert JSON value to string
    fn stringifyResponse(self: *@This(), response: std.json.Value) ![]const u8 {
        var result = std.ArrayList(u8).init(self.parent_allocator);
        try std.json.stringify(response, .{}, result.writer());
        return try result.toOwnedSlice();
    }

    /// Clean up server resources
    pub fn deinit(self: *@This()) void {
        // Clean up tool definitions
        var tool_iter = self.tools.iterator();
        while (tool_iter.next()) |entry| {
            const tool_def = entry.value_ptr.*;
            self.parent_allocator.free(tool_def.name);
            self.parent_allocator.free(tool_def.description);
            if (tool_def.input_schema) |schema| {
                self.parent_allocator.free(schema);
            }
        }
        self.tools.deinit();
    }
};

/// JSON-RPC error codes
const ErrorCode = enum(i32) {
    parseError = -32700,
    invalidRequest = -32600,
    methodNotFound = -32601,
    invalidParams = -32602,
    internalError = -32603,
    serverNotInitialized = -32099,
    unknownProtocolVersion = -32098,
    unknownTool = -32097,
};

/// Tracks an active MCP connection session
pub const Session = struct {
    allocator: std.mem.Allocator,
    connection: *network.Connection,
    tools: std.StringHashMap(*Tool),
    resources: std.StringHashMap(*Resource),
    capabilities: std.StringHashMap([]const u8),

    /// Initialize a new session
    pub fn init(allocator: std.mem.Allocator, connection: *network.Connection) !@This() {
        return .{
            .allocator = allocator,
            .connection = connection,
            .tools = std.StringHashMap(*Tool).init(allocator),
            .resources = std.StringHashMap(*Resource).init(allocator),
            .capabilities = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Process an incoming JSON-RPC message
    pub fn handleMessage(self: *@This(), message: jsonrpc.Message) !void {
        switch (message) {
            .request => |req| {
                if (std.mem.eql(u8, req.method, "registerTool")) {
                    try self.registerTool(req.params);
                } else if (std.mem.eql(u8, req.method, "discoverCapabilities")) {
                    try self.discoverCapabilities(req.id);
                } else {
                    return error.UnsupportedMethod;
                }
            },
            else => return error.InvalidMessageType,
        }
    }

    /// Register a new tool with the session
    pub fn registerTool(self: *@This(), params: jsonrpc.Params) !void {
        const tool_instance = switch (params) {
            .object => |obj| blk: {
                const name = obj.get("name") orelse return error.MissingToolName;
                const input_schema = obj.get("input_schema") orelse return error.MissingInputSchema;

                break :blk Tool{
                    .name = try self.allocator.dupe(u8, name.string),
                    .input_schema = try self.allocator.dupe(u8, input_schema.string),
                };
            },
            else => return error.InvalidParams,
        };

        try self.tools.put(tool_instance.name, &tool_instance);
    }

    /// Respond to capability discovery requests
    pub fn discoverCapabilities(self: *@This(), id: ?jsonrpc.Id) !void {
        var capabilities = std.ArrayList(jsonrpc.Value).init(self.allocator);
        defer capabilities.deinit();

        // TODO: Populate with actual capabilities
        try self.connection.respond(id, capabilities.items);
    }

    /// Clean up session resources
    pub fn deinit(self: *@This()) void {
        self.tools.deinit();
        self.resources.deinit();
        self.capabilities.deinit();
    }
};
