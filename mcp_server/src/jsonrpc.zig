const std = @import("std");
const Tool = @import("./primitives/tool.zig").Tool;
const Resource = @import("./primitives/resource.zig").Resource;
const ToolRegistry = @import("./primitives/tool.zig").ToolRegistry;
const Prompt = @import("./primitives/prompt.zig").Prompt;

/// JSON-RPC 2.0 Error codes
pub const ErrorCode = struct {
    pub const ParseError = -32700;
    pub const InvalidRequest = -32600;
    pub const MethodNotFound = -32601;
    pub const InvalidParams = -32602;
    pub const InternalError = -32603;
    pub const ServerError = -32000;
};

/// JSON-RPC 2.0 Error object
pub const Error = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};

/// JSON-RPC 2.0 Request object
pub const Request = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,
    id: ?std.json.Value = null,

    /// Parse JSON string into Request (single or batch)
    pub fn parseRequest(json: []const u8, allocator: std.mem.Allocator) !union(enum) { single: Request, batch: []Request } {
        // First try parsing as single request
        const single_parsed = std.json.parseFromSlice(Request, allocator, json, .{}) catch {
            // If parse failed, try as batch request
            const batch_parsed = try std.json.parseFromSlice([]Request, allocator, json, .{});
            defer batch_parsed.deinit();

            if (batch_parsed.value.len == 0) {
                return error.InvalidRequest;
            }

            // Validate each request in batch
            for (batch_parsed.value) |req| {
                if (!std.mem.eql(u8, req.jsonrpc, "2.0")) {
                    return error.InvalidVersion;
                }
                if (req.method.len == 0) {
                    return error.InvalidMethod;
                }
            }

            return .{ .batch = batch_parsed.value };
        };
        defer single_parsed.deinit();

        // Validate single request
        if (!std.mem.eql(u8, single_parsed.value.jsonrpc, "2.0")) {
            return error.InvalidVersion;
        }
        if (single_parsed.value.method.len == 0) {
            return error.InvalidMethod;
        }

        return .{ .single = single_parsed.value };
    }
};

/// JSON-RPC 2.0 Response object
pub const Response = struct {
    jsonrpc: []const u8 = "2.0",
    result: ?std.json.Value = null,
    err: ?Error = null,
    id: ?std.json.Value = null,

    /// Build response JSON string
    pub fn buildResponse(self: *const @This(), allocator: std.mem.Allocator) ![]const u8 {
        return try std.json.stringifyAlloc(allocator, self, .{});
    }

    /// Helper to build error response
    pub fn buildErrorResponse(code: i32, message: []const u8, id: ?std.json.Value, allocator: std.mem.Allocator) ![]const u8 {
        var response = Response{
            .err = .{
                .code = code,
                .message = message,
            },
            .id = id,
        };
        return try response.buildResponse(allocator);
    }
};

/// JSON-RPC module for handling MCP server communications
pub const JsonRpc = struct {
    allocator: std.mem.Allocator,
    tool_registry: *ToolRegistry,
    active_connections: std.AutoHashMap(u32, void),

    /// Initialize JSON-RPC handler
    pub fn init(allocator: std.mem.Allocator, tool_registry: *ToolRegistry) @This() {
        return .{
            .allocator = allocator,
            .tool_registry = tool_registry,
            .active_connections = std.AutoHashMap(u32, void).init(allocator),
        };
    }

    /// Process an incoming JSON-RPC request
    pub fn handleRequest(
        self: *@This(),
        request: []const u8,
        connection_id: u32,
    ) ![]const u8 {
        const req_or_batch = try Request.parseRequest(request, self.allocator);

        switch (req_or_batch) {
            .single => |req| {
                if (req.id == null) {
                    // Handle notification (no response needed)
                    _ = try self.processRequest(req, connection_id);
                    return "";
                }
                return try self.processRequest(req, connection_id);
            },
            .batch => |batch| {
                if (batch.len == 0) return "";

                var responses = std.ArrayList(u8).init(self.allocator);
                defer responses.deinit();

                try responses.append('[');
                var first = true;

                for (batch) |req| {
                    if (!first) try responses.append(',');
                    first = false;

                    if (req.id != null) {
                        const response = try self.processRequest(req, connection_id);
                        try responses.appendSlice(response);
                    } else {
                        // Skip notifications in batch response
                        _ = try self.processRequest(req, connection_id);
                    }
                }

                try responses.append(']');
                return responses.toOwnedSlice();
            },
        }
    }

    fn processRequest(
        self: *@This(),
        req: Request,
        connection_id: u32,
    ) ![]const u8 {
        errdefer if (req.id) |id| {
            _ = Response.buildErrorResponse(ErrorCode.InternalError, "Internal error", id, self.allocator) catch {};
        };

        try self.active_connections.put(connection_id, {});
        errdefer if (req.id) |id| {
            _ = Response.buildErrorResponse(ErrorCode.InternalError, "Internal error", id, self.allocator) catch {};
        };

        if (req.method.len == 0) {
            return Response.buildErrorResponse(ErrorCode.InvalidRequest, "Method cannot be empty", req.id, self.allocator);
        }

        if (std.mem.startsWith(u8, req.method, "tool.")) {
            return self.handleToolRequest(req);
        } else if (std.mem.startsWith(u8, req.method, "resource.")) {
            return self.handleResourceRequest(req);
        } else if (std.mem.startsWith(u8, req.method, "prompt.")) {
            return self.handlePromptRequest(req);
        }

        return Response.buildErrorResponse(ErrorCode.MethodNotFound, "Method not found", req.id, self.allocator);
    }

    /// Handle tool requests with proper MCP tool serialization
    fn handleToolRequest(self: *@This(), req: Request) ![]const u8 {
        const tool_name = req.method["tool.".len..];
        const params = req.params orelse return Response.buildErrorResponse(ErrorCode.InvalidParams, "Missing parameters", req.id, self.allocator);

        var param_map = std.StringHashMap(std.json.Value).init(self.allocator);
        defer param_map.deinit();

        if (params == .object) {
            var it = params.object.iterator();
            while (it.next()) |entry| {
                try param_map.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        const result = try self.tool_registry.invoke(tool_name, param_map);
        const json_result = try std.json.parseFromSlice(std.json.Value, self.allocator, result, .{});

        const response = Response{
            .result = json_result.value,
            .id = req.id,
        };
        return response.buildResponse(self.allocator);
    }

    /// Handle resource requests with MCP resource parsing
    fn handleResourceRequest(self: *@This(), req: Request) ![]const u8 {
        _ = req.method["resource.".len..]; // Resource URI extraction placeholder
        const params = req.params orelse return Response.buildErrorResponse(ErrorCode.InvalidParams, "Missing resource parameters", req.id, self.allocator);

        const resource = try Resource.fromJson(params, self.allocator);
        defer resource.deinit(self.allocator);

        // Process resource request here
        const result = try resource.fetch(self.allocator);
        const json_result = try std.json.parseFromSlice(std.json.Value, self.allocator, result, .{});

        const response = Response{
            .result = json_result.value,
            .id = req.id,
        };
        return response.buildResponse(self.allocator);
    }

    /// Handle prompt requests with MCP prompt handling
    fn handlePromptRequest(self: *@This(), req: Request) ![]const u8 {
        _ = req.method["prompt.".len..]; // Prompt type extraction placeholder
        const params = req.params orelse return Response.buildErrorResponse(ErrorCode.InvalidParams, "Missing prompt parameters", req.id, self.allocator);

        const prompt = try Prompt.fromJson(params, self.allocator);
        defer prompt.deinit(self.allocator);

        // Process prompt request here
        const result = try prompt.execute(self.allocator);
        const json_result = try std.json.parseFromSlice(std.json.Value, self.allocator, result, .{});

        const response = Response{
            .result = json_result.value,
            .id = req.id,
        };
        return response.buildResponse(self.allocator);
    }

    pub fn deinit(self: *@This()) void {
        self.active_connections.deinit();
    }
};

test "JSON-RPC full message handling" {
    const allocator = std.testing.allocator;

    const json =
        \\{"jsonrpc":"2.0","method":"resource.fetch",
        \\"params":{"uri":"weather://san-francisco/current"},
        \\"id":"req-123"}
    ;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc = JsonRpc.init(allocator, &tool_registry);
    defer rpc.deinit();

    const response = try rpc.handleRequest(json, 1);
    defer allocator.free(response);

    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "jsonrpc"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "req-123"));
}

test "MCP tool parameter serialization" {
    const allocator = std.testing.allocator;

    const json =
        \\{"jsonrpc":"2.0","method":"tool.calculate",
        \\"params":{"expression":"2+2"},
        \\"id":1}
    ;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc = JsonRpc.init(allocator, &tool_registry);
    defer rpc.deinit();

    const response = try rpc.handleRequest(json, 1);
    defer allocator.free(response);

    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "jsonrpc"));
}

test "Error handling for invalid JSON-RPC" {
    const allocator = std.testing.allocator;

    const json =
        \\{"jsonrpc":"2.0","method":123,"id":1}
    ;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc = JsonRpc.init(allocator, &tool_registry);
    defer rpc.deinit();

    const response = try rpc.handleRequest(json, 1);
    defer allocator.free(response);

    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "InvalidRequest"));
}

test "Batch request handling" {
    const allocator = std.testing.allocator;

    const json =
        \\[{"jsonrpc":"2.0","method":"tool.test","params":{},"id":1},
        \\{"jsonrpc":"2.0","method":"resource.test","params":{},"id":2},
        \\{"jsonrpc":"2.0","method":"prompt.test","params":{}}]
    ;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc = JsonRpc.init(allocator, &tool_registry);
    defer rpc.deinit();

    const response = try rpc.handleRequest(json, 1);
    defer allocator.free(response);

    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "["));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "2"));
}

test "Notification handling" {
    const allocator = std.testing.allocator;

    const json =
        \\{"jsonrpc":"2.0","method":"tool.test","params":{}}
    ;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc = JsonRpc.init(allocator, &tool_registry);
    defer rpc.deinit();

    const response = try rpc.handleRequest(json, 1);
    defer allocator.free(response);

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

    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "InvalidVersion"));
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

    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "InvalidRequest"));
}
