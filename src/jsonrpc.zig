const std = @import("std");
const Tool = @import("./primitives/tool.zig").Tool;
const ToolRegistry = @import("./primitives/tool.zig").ToolRegistry;
const Resource = @import("./primitives/resource.zig").Resource;
const ResourceRegistry = @import("./primitives/resource.zig").ResourceRegistry;
const ResourceContent = @import("./primitives/resource.zig").ResourceContent;
const Prompt = @import("./primitives/prompt.zig").Prompt;
const PromptRegistry = @import("./primitives/prompt.zig").PromptRegistry;

/// JSON-RPC protocol version
pub const VERSION = "2.0";

/// JSON-RPC 2.0 Error codes
pub const ErrorCode = struct {
    pub const ParseError: i32 = -32700;
    pub const InvalidRequest: i32 = -32600;
    pub const MethodNotFound: i32 = -32601;
    pub const InvalidParams: i32 = -32602;
    pub const InternalError: i32 = -32603;
    pub const ServerError: i32 = -32000;
};

/// Request ID can be string or integer
pub const RequestId = union(enum) {
    string: []const u8,
    integer: i64,

    pub fn eql(self: RequestId, other: RequestId) bool {
        return switch (self) {
            .string => |s| switch (other) {
                .string => |os| std.mem.eql(u8, s, os),
                .integer => false,
            },
            .integer => |i| switch (other) {
                .string => false,
                .integer => |oi| i == oi,
            },
        };
    }
};

/// JSON-RPC 2.0 Error object
pub const Error = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};

/// JSON-RPC 2.0 Request object
pub const Request = struct {
    jsonrpc: []const u8 = VERSION,
    method: []const u8,
    params: ?std.json.Value = null,
    id: ?RequestId = null,
};

/// JSON-RPC 2.0 Response object
pub const Response = struct {
    jsonrpc: []const u8 = VERSION,
    result: ?std.json.Value = null,
    err: ?Error = null,
    id: ?RequestId = null,
};

/// Parsed message result - keeps the underlying JSON alive
pub const ParsedRequest = struct {
    request: Request,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *ParsedRequest) void {
        self.parsed.deinit();
    }
};

/// Errors during parsing
pub const ParseError = error{
    InvalidJson,
    MissingVersion,
    InvalidVersion,
    MissingMethod,
    InvalidMessage,
    OutOfMemory,
};

/// Parse a JSON-RPC request, keeping the parsed JSON alive
pub fn parseRequest(allocator: std.mem.Allocator, json_str: []const u8) ParseError!ParsedRequest {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return ParseError.InvalidJson;
    };
    errdefer parsed.deinit();

    if (parsed.value != .object) {
        return ParseError.InvalidMessage;
    }

    const obj = parsed.value.object;

    // Validate jsonrpc version
    if (obj.get("jsonrpc")) |version_val| {
        if (version_val != .string or !std.mem.eql(u8, version_val.string, VERSION)) {
            return ParseError.InvalidVersion;
        }
    } else {
        return ParseError.MissingVersion;
    }

    // Get method
    const method_val = obj.get("method") orelse return ParseError.MissingMethod;
    if (method_val != .string) {
        return ParseError.InvalidMessage;
    }

    // Parse ID if present
    const id: ?RequestId = if (obj.get("id")) |id_val| switch (id_val) {
        .string => |s| RequestId{ .string = s },
        .integer => |i| RequestId{ .integer = i },
        .null => null,
        else => return ParseError.InvalidMessage,
    } else null;

    return ParsedRequest{
        .request = Request{
            .method = method_val.string,
            .params = obj.get("params"),
            .id = id,
        },
        .parsed = parsed,
    };
}

/// Serialize a request ID to a buffer
fn serializeRequestId(allocator: std.mem.Allocator, buffer: *std.ArrayListUnmanaged(u8), id: RequestId) !void {
    switch (id) {
        .string => |s| {
            try buffer.appendSlice(allocator, "\"");
            try buffer.appendSlice(allocator, s);
            try buffer.appendSlice(allocator, "\"");
        },
        .integer => |i| {
            var int_buf: [32]u8 = undefined;
            const int_str = std.fmt.bufPrint(&int_buf, "{d}", .{i}) catch "0";
            try buffer.appendSlice(allocator, int_str);
        },
    }
}

/// Serialize a JSON value to a buffer
fn serializeValue(allocator: std.mem.Allocator, buffer: *std.ArrayListUnmanaged(u8), value: std.json.Value) !void {
    switch (value) {
        .null => try buffer.appendSlice(allocator, "null"),
        .bool => |b| try buffer.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            var int_buf: [32]u8 = undefined;
            const int_str = std.fmt.bufPrint(&int_buf, "{d}", .{i}) catch "0";
            try buffer.appendSlice(allocator, int_str);
        },
        .float => |f| {
            var float_buf: [64]u8 = undefined;
            const float_str = std.fmt.bufPrint(&float_buf, "{d}", .{f}) catch "0";
            try buffer.appendSlice(allocator, float_str);
        },
        .string => |s| {
            try buffer.appendSlice(allocator, "\"");
            for (s) |c| {
                switch (c) {
                    '"' => try buffer.appendSlice(allocator, "\\\""),
                    '\\' => try buffer.appendSlice(allocator, "\\\\"),
                    '\n' => try buffer.appendSlice(allocator, "\\n"),
                    '\r' => try buffer.appendSlice(allocator, "\\r"),
                    '\t' => try buffer.appendSlice(allocator, "\\t"),
                    else => try buffer.append(allocator, c),
                }
            }
            try buffer.appendSlice(allocator, "\"");
        },
        .array => |arr| {
            try buffer.appendSlice(allocator, "[");
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buffer.appendSlice(allocator, ",");
                try serializeValue(allocator, buffer, item);
            }
            try buffer.appendSlice(allocator, "]");
        },
        .object => |obj| {
            try buffer.appendSlice(allocator, "{");
            var first = true;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                if (!first) try buffer.appendSlice(allocator, ",");
                first = false;
                try buffer.appendSlice(allocator, "\"");
                try buffer.appendSlice(allocator, entry.key_ptr.*);
                try buffer.appendSlice(allocator, "\":");
                try serializeValue(allocator, buffer, entry.value_ptr.*);
            }
            try buffer.appendSlice(allocator, "}");
        },
        .number_string => |s| try buffer.appendSlice(allocator, s),
    }
}

/// Build a success response
pub fn buildResponse(allocator: std.mem.Allocator, id: ?RequestId, result: ?std.json.Value) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8){};
    errdefer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |req_id| {
        try serializeRequestId(allocator, &buffer, req_id);
    } else {
        try buffer.appendSlice(allocator, "null");
    }
    try buffer.appendSlice(allocator, ",\"result\":");
    if (result) |res| {
        try serializeValue(allocator, &buffer, res);
    } else {
        try buffer.appendSlice(allocator, "null");
    }
    try buffer.appendSlice(allocator, "}");

    return buffer.toOwnedSlice(allocator);
}

/// Build an error response
pub fn buildErrorResponse(allocator: std.mem.Allocator, code: i32, message: []const u8, id: ?RequestId) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8){};
    errdefer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |req_id| {
        try serializeRequestId(allocator, &buffer, req_id);
    } else {
        try buffer.appendSlice(allocator, "null");
    }
    try buffer.appendSlice(allocator, ",\"error\":{\"code\":");
    var code_buf: [16]u8 = undefined;
    const code_str = std.fmt.bufPrint(&code_buf, "{d}", .{code}) catch "0";
    try buffer.appendSlice(allocator, code_str);
    try buffer.appendSlice(allocator, ",\"message\":\"");
    try buffer.appendSlice(allocator, message);
    try buffer.appendSlice(allocator, "\"}}");

    return buffer.toOwnedSlice(allocator);
}

/// JSON-RPC module for handling MCP server communications
pub const JsonRpc = struct {
    allocator: std.mem.Allocator,
    tool_registry: *ToolRegistry,
    resource_registry: ?*ResourceRegistry = null,
    prompt_registry: ?*PromptRegistry = null,
    active_connections: std.AutoHashMap(u32, void),

    /// Initialize JSON-RPC handler
    pub fn init(allocator: std.mem.Allocator, tool_registry: *ToolRegistry) @This() {
        return .{
            .allocator = allocator,
            .tool_registry = tool_registry,
            .active_connections = std.AutoHashMap(u32, void).init(allocator),
        };
    }

    /// Initialize JSON-RPC handler with all registries
    pub fn initFull(
        allocator: std.mem.Allocator,
        tool_registry: *ToolRegistry,
        resource_registry: ?*ResourceRegistry,
        prompt_registry: ?*PromptRegistry,
    ) @This() {
        return .{
            .allocator = allocator,
            .tool_registry = tool_registry,
            .resource_registry = resource_registry,
            .prompt_registry = prompt_registry,
            .active_connections = std.AutoHashMap(u32, void).init(allocator),
        };
    }

    /// Process an incoming JSON-RPC request
    pub fn handleRequest(
        self: *@This(),
        request_json: []const u8,
        connection_id: u32,
    ) ![]const u8 {
        var parsed = parseRequest(self.allocator, request_json) catch |err| {
            return switch (err) {
                ParseError.InvalidJson => buildErrorResponse(self.allocator, ErrorCode.ParseError, "Invalid JSON", null),
                ParseError.MissingVersion, ParseError.InvalidVersion => buildErrorResponse(self.allocator, ErrorCode.InvalidRequest, "Invalid JSON-RPC version", null),
                ParseError.MissingMethod, ParseError.InvalidMessage => buildErrorResponse(self.allocator, ErrorCode.InvalidRequest, "Invalid request", null),
                else => buildErrorResponse(self.allocator, ErrorCode.InternalError, "Internal error", null),
            };
        };
        defer parsed.deinit();

        const req = parsed.request;

        if (req.id == null) {
            // Handle notification (no response needed)
            // Free any allocated response since notifications don't respond
            const result = self.processRequest(req, connection_id) catch "";
            if (result.len > 0) {
                self.allocator.free(result);
            }
            return "";
        }
        return try self.processRequest(req, connection_id);
    }

    fn processRequest(
        self: *@This(),
        req: Request,
        connection_id: u32,
    ) ![]const u8 {
        try self.active_connections.put(connection_id, {});

        if (req.method.len == 0) {
            return buildErrorResponse(self.allocator, ErrorCode.InvalidRequest, "Method cannot be empty", req.id);
        }

        if (std.mem.startsWith(u8, req.method, "tool.")) {
            return self.handleToolRequest(req);
        } else if (std.mem.startsWith(u8, req.method, "resource.")) {
            return self.handleResourceRequest(req);
        } else if (std.mem.startsWith(u8, req.method, "prompt.")) {
            return self.handlePromptRequest(req);
        }

        return buildErrorResponse(self.allocator, ErrorCode.MethodNotFound, "Method not found", req.id);
    }

    /// Handle tool requests with proper MCP tool serialization
    fn handleToolRequest(self: *@This(), req: Request) ![]const u8 {
        const tool_name = req.method["tool.".len..];
        const params = req.params orelse return buildErrorResponse(self.allocator, ErrorCode.InvalidParams, "Missing parameters", req.id);

        // Convert JSON values to strings for old tool API
        var param_map = std.StringHashMap([]const u8).init(self.allocator);
        defer param_map.deinit();

        if (params == .object) {
            var it = params.object.iterator();
            while (it.next()) |entry| {
                const value_str = switch (entry.value_ptr.*) {
                    .string => |s| s,
                    .integer => |i| try std.fmt.allocPrint(self.allocator, "{d}", .{i}),
                    .float => |f| try std.fmt.allocPrint(self.allocator, "{d}", .{f}),
                    .bool => |b| if (b) "true" else "false",
                    else => "null",
                };
                try param_map.put(entry.key_ptr.*, value_str);
            }
        }

        const result = self.tool_registry.invoke(tool_name, param_map) catch |err| {
            return switch (err) {
                error.ToolNotFound => buildErrorResponse(self.allocator, ErrorCode.MethodNotFound, "Tool not found", req.id),
                else => buildErrorResponse(self.allocator, ErrorCode.InternalError, "Tool execution failed", req.id),
            };
        };
        const json_result = try std.json.parseFromSlice(std.json.Value, self.allocator, result, .{});
        defer json_result.deinit();

        return buildResponse(self.allocator, req.id, json_result.value);
    }

    /// Handle resource requests (resources/list, resources/read)
    fn handleResourceRequest(self: *@This(), req: Request) ![]const u8 {
        const registry = self.resource_registry orelse {
            return buildErrorResponse(self.allocator, ErrorCode.MethodNotFound, "Resources not supported", req.id);
        };

        const action = req.method["resource.".len..];

        if (std.mem.eql(u8, action, "list")) {
            // Return list of available resources
            var resources_array = std.ArrayListUnmanaged(std.json.Value){};

            var it = registry.resources.iterator();
            while (it.next()) |entry| {
                const resource = entry.value_ptr.*;
                var resource_obj = std.json.ObjectMap.init(self.allocator);
                try resource_obj.put("uri", std.json.Value{ .string = resource.uri });
                try resource_obj.put("name", std.json.Value{ .string = resource.name });
                if (resource.description) |desc| {
                    try resource_obj.put("description", std.json.Value{ .string = desc });
                }
                if (resource.mimeType) |mime| {
                    try resource_obj.put("mimeType", std.json.Value{ .string = mime });
                }
                try resources_array.append(self.allocator, std.json.Value{ .object = resource_obj });
            }

            var result_obj = std.json.ObjectMap.init(self.allocator);
            const slice = try resources_array.toOwnedSlice(self.allocator);
            try result_obj.put("resources", std.json.Value{ .array = std.json.Array.fromOwnedSlice(self.allocator, slice) });

            return buildResponse(self.allocator, req.id, std.json.Value{ .object = result_obj });
        } else if (std.mem.eql(u8, action, "read")) {
            // Read a specific resource
            const params = req.params orelse return buildErrorResponse(self.allocator, ErrorCode.InvalidParams, "Missing uri parameter", req.id);
            const uri = if (params == .object) params.object.get("uri") else null;
            if (uri == null or uri.? != .string) {
                return buildErrorResponse(self.allocator, ErrorCode.InvalidParams, "Invalid uri parameter", req.id);
            }

            const content = registry.read(uri.?.string) catch |err| {
                return switch (err) {
                    error.ResourceNotFound => buildErrorResponse(self.allocator, ErrorCode.InvalidParams, "Resource not found", req.id),
                    error.NoHandler => buildErrorResponse(self.allocator, ErrorCode.InternalError, "Resource has no handler", req.id),
                    else => buildErrorResponse(self.allocator, ErrorCode.InternalError, "Failed to read resource", req.id),
                };
            };

            var content_obj = std.json.ObjectMap.init(self.allocator);
            try content_obj.put("uri", std.json.Value{ .string = content.uri });
            if (content.mimeType) |mime| {
                try content_obj.put("mimeType", std.json.Value{ .string = mime });
            }
            if (content.text) |text| {
                try content_obj.put("text", std.json.Value{ .string = text });
            }
            if (content.blob) |blob| {
                try content_obj.put("blob", std.json.Value{ .string = blob });
            }

            var contents_array = std.ArrayListUnmanaged(std.json.Value){};
            try contents_array.append(self.allocator, std.json.Value{ .object = content_obj });

            var result_obj = std.json.ObjectMap.init(self.allocator);
            const contents_slice = try contents_array.toOwnedSlice(self.allocator);
            try result_obj.put("contents", std.json.Value{ .array = std.json.Array.fromOwnedSlice(self.allocator, contents_slice) });

            return buildResponse(self.allocator, req.id, std.json.Value{ .object = result_obj });
        }

        return buildErrorResponse(self.allocator, ErrorCode.MethodNotFound, "Unknown resource action", req.id);
    }

    /// Handle prompt requests (prompts/list, prompts/get)
    fn handlePromptRequest(self: *@This(), req: Request) ![]const u8 {
        const registry = self.prompt_registry orelse {
            return buildErrorResponse(self.allocator, ErrorCode.MethodNotFound, "Prompts not supported", req.id);
        };

        const action = req.method["prompt.".len..];

        if (std.mem.eql(u8, action, "list")) {
            // Return list of available prompts
            var prompts_array = std.ArrayListUnmanaged(std.json.Value){};

            var it = registry.prompts.iterator();
            while (it.next()) |entry| {
                const prompt = entry.value_ptr.*;
                var prompt_obj = std.json.ObjectMap.init(self.allocator);
                try prompt_obj.put("name", std.json.Value{ .string = prompt.name });
                if (prompt.description) |desc| {
                    try prompt_obj.put("description", std.json.Value{ .string = desc });
                }
                if (prompt.arguments) |args| {
                    var args_array = std.ArrayListUnmanaged(std.json.Value){};
                    for (args) |arg| {
                        var arg_obj = std.json.ObjectMap.init(self.allocator);
                        try arg_obj.put("name", std.json.Value{ .string = arg.name });
                        if (arg.description) |desc| {
                            try arg_obj.put("description", std.json.Value{ .string = desc });
                        }
                        try arg_obj.put("required", std.json.Value{ .bool = arg.required });
                        try args_array.append(self.allocator, std.json.Value{ .object = arg_obj });
                    }
                    const args_slice = try args_array.toOwnedSlice(self.allocator);
                    try prompt_obj.put("arguments", std.json.Value{ .array = std.json.Array.fromOwnedSlice(self.allocator, args_slice) });
                }
                try prompts_array.append(self.allocator, std.json.Value{ .object = prompt_obj });
            }

            var result_obj = std.json.ObjectMap.init(self.allocator);
            const prompts_slice = try prompts_array.toOwnedSlice(self.allocator);
            try result_obj.put("prompts", std.json.Value{ .array = std.json.Array.fromOwnedSlice(self.allocator, prompts_slice) });

            return buildResponse(self.allocator, req.id, std.json.Value{ .object = result_obj });
        } else if (std.mem.eql(u8, action, "get")) {
            // Get/execute a specific prompt
            const params = req.params orelse return buildErrorResponse(self.allocator, ErrorCode.InvalidParams, "Missing name parameter", req.id);
            const name = if (params == .object) params.object.get("name") else null;
            if (name == null or name.? != .string) {
                return buildErrorResponse(self.allocator, ErrorCode.InvalidParams, "Invalid name parameter", req.id);
            }

            const arguments = if (params == .object) params.object.get("arguments") else null;

            const result = registry.execute(name.?.string, arguments) catch |err| {
                return switch (err) {
                    error.PromptNotFound => buildErrorResponse(self.allocator, ErrorCode.InvalidParams, "Prompt not found", req.id),
                    error.NoHandler => buildErrorResponse(self.allocator, ErrorCode.InternalError, "Prompt has no handler", req.id),
                    else => buildErrorResponse(self.allocator, ErrorCode.InternalError, "Failed to execute prompt", req.id),
                };
            };

            var messages_array = std.ArrayListUnmanaged(std.json.Value){};
            for (result.messages) |msg| {
                var msg_obj = std.json.ObjectMap.init(self.allocator);
                try msg_obj.put("role", std.json.Value{ .string = msg.role });

                var content_obj = std.json.ObjectMap.init(self.allocator);
                try content_obj.put("type", std.json.Value{ .string = "text" });
                try content_obj.put("text", std.json.Value{ .string = msg.content });
                try msg_obj.put("content", std.json.Value{ .object = content_obj });

                try messages_array.append(self.allocator, std.json.Value{ .object = msg_obj });
            }

            var result_obj = std.json.ObjectMap.init(self.allocator);
            if (result.description) |desc| {
                try result_obj.put("description", std.json.Value{ .string = desc });
            }
            const messages_slice = try messages_array.toOwnedSlice(self.allocator);
            try result_obj.put("messages", std.json.Value{ .array = std.json.Array.fromOwnedSlice(self.allocator, messages_slice) });

            return buildResponse(self.allocator, req.id, std.json.Value{ .object = result_obj });
        }

        return buildErrorResponse(self.allocator, ErrorCode.MethodNotFound, "Unknown prompt action", req.id);
    }

    pub fn deinit(self: *@This()) void {
        self.active_connections.deinit();
    }
};

// ==================== Tests ====================

test "parseRequest with valid request" {
    const allocator = std.testing.allocator;
    const json = "{\"jsonrpc\":\"2.0\",\"method\":\"test\",\"id\":1}";

    var parsed = try parseRequest(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test", parsed.request.method);
    try std.testing.expectEqual(RequestId{ .integer = 1 }, parsed.request.id.?);
}

test "parseRequest with string id" {
    const allocator = std.testing.allocator;
    const json = "{\"jsonrpc\":\"2.0\",\"method\":\"test\",\"id\":\"abc-123\"}";

    var parsed = try parseRequest(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("abc-123", parsed.request.id.?.string);
}

test "parseRequest rejects invalid version" {
    const allocator = std.testing.allocator;
    const json = "{\"jsonrpc\":\"1.0\",\"method\":\"test\",\"id\":1}";

    const result = parseRequest(allocator, json);
    try std.testing.expectError(ParseError.InvalidVersion, result);
}

test "parseRequest rejects missing method" {
    const allocator = std.testing.allocator;
    const json = "{\"jsonrpc\":\"2.0\",\"id\":1}";

    const result = parseRequest(allocator, json);
    try std.testing.expectError(ParseError.MissingMethod, result);
}

test "buildResponse produces valid JSON" {
    const allocator = std.testing.allocator;

    const response = try buildResponse(allocator, RequestId{ .integer = 42 }, std.json.Value{ .string = "hello" });
    defer allocator.free(response);

    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"jsonrpc\":\"2.0\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"id\":42"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"result\":\"hello\""));
}

test "buildErrorResponse produces valid JSON" {
    const allocator = std.testing.allocator;

    const response = try buildErrorResponse(allocator, ErrorCode.MethodNotFound, "Method not found", RequestId{ .string = "req-1" });
    defer allocator.free(response);

    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"jsonrpc\":\"2.0\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"id\":\"req-1\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"error\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "-32601"));
}

test "JSON-RPC full message handling" {
    const allocator = std.testing.allocator;

    const json =
        \\{"jsonrpc":"2.0","method":"unknown_method","params":{},"id":123}
    ;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc = JsonRpc.init(allocator, &tool_registry);
    defer rpc.deinit();

    const response = try rpc.handleRequest(json, 1);
    defer allocator.free(response);

    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "jsonrpc"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "Method not found"));
}

test "MCP tool request with tool not found" {
    const allocator = std.testing.allocator;

    const json =
        \\{"jsonrpc":"2.0","method":"tool.calculate","params":{"expression":"2+2"},"id":1}
    ;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc = JsonRpc.init(allocator, &tool_registry);
    defer rpc.deinit();

    const response = try rpc.handleRequest(json, 1);
    defer allocator.free(response);

    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "jsonrpc"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "Tool not found"));
}

test "Notification handling" {
    const allocator = std.testing.allocator;

    // Notification has no id - should return empty response without allocation
    const json =
        \\{"jsonrpc":"2.0","method":"notify.test","params":{}}
    ;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc = JsonRpc.init(allocator, &tool_registry);
    defer rpc.deinit();

    const response = try rpc.handleRequest(json, 1);
    // Empty string means notification was processed (no response expected)
    try std.testing.expectEqualStrings("", response);
}

test "Invalid version handling" {
    const allocator = std.testing.allocator;

    const json =
        \\{"jsonrpc":"1.0","method":"tool.test","params":{},"id":1}
    ;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc = JsonRpc.init(allocator, &tool_registry);
    defer rpc.deinit();

    const response = try rpc.handleRequest(json, 1);
    defer allocator.free(response);

    // Check for error response with version message
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "version"));
}

test "Empty method validation" {
    const allocator = std.testing.allocator;

    const json =
        \\{"jsonrpc":"2.0","method":"","params":{},"id":1}
    ;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc = JsonRpc.init(allocator, &tool_registry);
    defer rpc.deinit();

    const response = try rpc.handleRequest(json, 1);
    defer allocator.free(response);

    // Check for error response about empty method
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "empty"));
}
