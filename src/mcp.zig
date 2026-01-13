const std = @import("std");
const builtin = @import("builtin");
const tool = @import("primitives/tool.zig");
const Tool = tool.Tool;
const Resource = @import("primitives/resource.zig");
const jsonrpc = @import("jsonrpc.zig");
const network = @import("network.zig");
const constants = @import("constants.zig");
const types = @import("types.zig");

/// MCP Protocol version - aligned with latest specification
pub const PROTOCOL_VERSION = constants.MCP_PROTOCOL_VERSION;

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

/// Tool handler function signature with cancellation support
pub const ToolHandlerWithCancellation = *const fn (allocator: std.mem.Allocator, params: std.json.Value, cancellation_token: ?*CancellationToken) anyerror!std.json.Value;

/// Sampling handler function signature
pub const SamplingHandler = *const fn (allocator: std.mem.Allocator, request: types.CreateMessageRequest) anyerror!types.CreateMessageResult;

/// MCP Tool definition - simplified from reference patterns
pub const MCPTool = struct {
    name: []const u8,
    description: []const u8,
    handler: ToolHandler,
    handler_with_cancellation: ?ToolHandlerWithCancellation = null,
    input_schema: ?[]const u8 = null,
};

/// Request cancellation token
pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool),
    reason: ?[]const u8,

    pub fn init() @This() {
        return .{
            .cancelled = std.atomic.Value(bool).init(false),
            .reason = null,
        };
    }

    pub fn cancel(self: *@This(), reason: ?[]const u8) void {
        self.cancelled.store(true, .release);
        self.reason = reason;
    }

    pub fn isCancelled(self: *@This()) bool {
        return self.cancelled.load(.acquire);
    }
};

/// Enhanced MCP Server implementation
/// Incorporates arena allocator patterns and improved error handling from zig-mcp-server reference
pub const MCPServer = struct {
    parent_allocator: std.mem.Allocator,
    state: ServerState,
    tools: std.StringHashMap(MCPTool),
    sampling_handler: ?SamplingHandler = null,
    request_context: ?*std.heap.ArenaAllocator = null,
    active_requests: std.AutoHashMap(u64, *CancellationToken),

    /// Initialize a new MCP server instance
    pub fn init(allocator: std.mem.Allocator) !@This() {
        const tools = std.StringHashMap(MCPTool).init(allocator);
        const active_requests = std.AutoHashMap(u64, *CancellationToken).init(allocator);

        return .{
            .parent_allocator = allocator,
            .state = .created,
            .tools = tools,
            .active_requests = active_requests,
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

    /// Set the sampling handler for server-initiated LLM sampling
    pub fn setSamplingHandler(self: *@This(), handler: SamplingHandler) void {
        self.sampling_handler = handler;
        std.log.debug("Sampling handler registered", .{});
    }

    /// Get a hashable ID from RequestId
    fn getRequestIdHash(id: jsonrpc.RequestId) u64 {
        return switch (id) {
            .string => |s| std.hash.Wyhash.hash(0, s),
            .integer => |i| @as(u64, @intCast(i)),
        };
    }

    /// Register a request for potential cancellation
    pub fn registerRequest(self: *@This(), request_id: jsonrpc.RequestId) !*CancellationToken {
        const hash = getRequestIdHash(request_id);
        const token = try self.parent_allocator.create(CancellationToken);
        token.* = CancellationToken.init();
        try self.active_requests.put(hash, token);
        return token;
    }

    /// Cancel a request by ID
    pub fn cancelRequest(self: *@This(), request_id: jsonrpc.RequestId, reason: ?[]const u8) !bool {
        const hash = getRequestIdHash(request_id);
        if (self.active_requests.get(hash)) |token| {
            token.cancel(reason);
            return true;
        }
        return false;
    }

    /// Check if a request is cancelled
    pub fn isRequestCancelled(self: *@This(), request_id: jsonrpc.RequestId) bool {
        const hash = getRequestIdHash(request_id);
        if (self.active_requests.get(hash)) |token| {
            return token.isCancelled();
        }
        return false;
    }

    /// Clean up a completed request
    pub fn completeRequest(self: *@This(), request_id: jsonrpc.RequestId) void {
        const hash = getRequestIdHash(request_id);
        if (self.active_requests.fetchRemove(hash)) |entry| {
            self.parent_allocator.destroy(entry.value);
        }
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
        } else if (std.mem.eql(u8, method.string, "sampling/createMessage")) {
            return try self.handleSamplingCreateMessage(arena, params, id);
        } else if (std.mem.eql(u8, method.string, "notifications/cancelled")) {
            return try self.handleCancellation(arena, params);
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

        // Add sampling capability if handler is registered
        if (self.sampling_handler != null) {
            try capabilities.object.put("sampling", std.json.Value{ .bool = true });
        }

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

        // Convert id to RequestId for cancellation tracking
        var request_id: ?jsonrpc.RequestId = null;
        if (id) |id_val| {
            request_id = switch (id_val) {
                .string => |s| jsonrpc.RequestId{ .string = s },
                .integer => |i| jsonrpc.RequestId{ .integer = i },
                else => null,
            };
        }

        // Register the request for cancellation if we have a handler that supports it
        var cancellation_token: ?*CancellationToken = null;
        if (tool_def.handler_with_cancellation != null and request_id != null) {
            cancellation_token = try self.registerRequest(request_id.?);
        }

        // Ensure we clean up the cancellation token when done
        defer {
            if (cancellation_token != null and request_id != null) {
                self.completeRequest(request_id.?);
            }
        }

        // Execute the tool with the appropriate handler
        const tool_result = blk: {
            if (tool_def.handler_with_cancellation != null) {
                break :blk tool_def.handler_with_cancellation.?(arena, tool_params, cancellation_token);
            } else {
                break :blk tool_def.handler(arena, tool_params);
            }
        } catch |err| {
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
                var out: std.io.Writer.Allocating = .init(arena);
                errdefer out.deinit();
                var stringify: std.json.Stringify = .{
                    .writer = &out.writer,
                };
                try stringify.write(tool_result);
                break :blk try out.toOwnedSlice();
            },
        };

        try content_obj.object.put("text", std.json.Value{ .string = text_result });
        try content_array.append(content_obj);

        var result = std.json.Value{ .object = std.json.ObjectMap.init(arena) };
        try result.object.put("content", std.json.Value{ .array = content_array });

        const response = try self.createSuccessResponse(arena, id, result);
        return try self.stringifyResponse(response);
    }

    /// Handle sampling/createMessage request
    fn handleSamplingCreateMessage(self: *@This(), arena: std.mem.Allocator, params: std.json.Value, id: ?std.json.Value) ![]const u8 {
        // Check if sampling handler is registered
        const handler = self.sampling_handler orelse {
            const error_response = try self.createErrorResponse(arena, id, .methodNotFound, "Sampling not supported - no handler registered");
            return try self.stringifyResponse(error_response);
        };

        // Parse the sampling request
        const create_request = try std.json.parseFromValue(types.CreateMessageRequest, arena, params, .{});

        // Call the sampling handler
        const result = try handler(arena, create_request.value);

        // Convert result to JSON response
        var json_result_map = std.json.ObjectMap.init(arena);
        const json_result = std.json.Value{ .object = json_result_map };

        try json_result_map.put("role", std.json.Value{ .string = result.role });

        // Convert content based on type
        switch (result.content) {
            .text => |text| {
                var content_obj = std.json.Value{ .object = std.json.ObjectMap.init(arena) };
                try content_obj.object.put("type", std.json.Value{ .string = "text" });
                try content_obj.object.put("text", std.json.Value{ .string = text.text });
                try json_result_map.put("content", content_obj);
            },
            else => {
                const error_response = try self.createErrorResponse(arena, id, .internalError, "Unsupported content type in sampling result");
                return try self.stringifyResponse(error_response);
            },
        }

        try json_result_map.put("model", std.json.Value{ .string = result.model });

        if (result.stopReason) |stop_reason| {
            try json_result_map.put("stopReason", std.json.Value{ .string = stop_reason });
        }

        const response = try self.createSuccessResponse(arena, id, json_result);
        return try self.stringifyResponse(response);
    }

    /// Handle request cancellation notifications
    fn handleCancellation(self: *@This(), arena: std.mem.Allocator, params: std.json.Value) ![]const u8 {
        _ = arena; // Notification - no response needed

        // Parse the cancellation notification
        const cancellation = try std.json.parseFromValue(types.CancelledNotification, self.parent_allocator, params, .{});
        defer cancellation.deinit();

        // Attempt to cancel the request
        const cancelled = try self.cancelRequest(cancellation.value.requestId, cancellation.value.reason);

        if (cancelled) {
            std.log.debug("Request cancelled: {any}", .{cancellation.value.requestId});
        } else {
            std.log.debug("Request not found for cancellation: {any}", .{cancellation.value.requestId});
        }

        // Cancellation notifications don't require a response
        return try self.parent_allocator.dupe(u8, "");
    }

    /// Create a JSON-RPC success response
    fn createSuccessResponse(self: *@This(), arena: std.mem.Allocator, id: ?std.json.Value, result: std.json.Value) !std.json.Value {
        _ = self;
        var response = std.json.Value{ .object = std.json.ObjectMap.init(arena) };
        try response.object.put("jsonrpc", std.json.Value{ .string = constants.JSON_RPC_VERSION });
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
        try response.object.put("jsonrpc", std.json.Value{ .string = constants.JSON_RPC_VERSION });
        try response.object.put("error", error_obj);

        if (id) |id_val| {
            try response.object.put("id", id_val);
        }

        return response;
    }

    /// Convert JSON value to string
    fn stringifyResponse(self: *@This(), response: std.json.Value) ![]const u8 {
        var out: std.io.Writer.Allocating = .init(self.parent_allocator);
        errdefer out.deinit();
        var stringify: std.json.Stringify = .{
            .writer = &out.writer,
        };
        try stringify.write(response);
        return out.toOwnedSlice();
    }

    /// Clean up server resources
    pub fn deinit(self: *@This()) void {
        // Clean up active requests
        var request_iter = self.active_requests.iterator();
        while (request_iter.next()) |entry| {
            self.parent_allocator.destroy(entry.value_ptr.*);
        }
        self.active_requests.deinit();

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
    state: ServerState = .created,
    session_id: u32,

    /// Initialize a new session
    pub fn init(allocator: std.mem.Allocator, connection: *network.Connection) !@This() {
        return .{
            .allocator = allocator,
            .connection = connection,
            .tools = std.StringHashMap(*Tool).init(allocator),
            .resources = std.StringHashMap(*Resource).init(allocator),
            .capabilities = std.StringHashMap([]const u8).init(allocator),
            .session_id = std.time.timestamp(),
        };
    }

    /// Process an incoming JSON-RPC message
    pub fn handleMessage(self: *@This(), message: jsonrpc.Message) !void {
        switch (message) {
            .request => |req| {
                if (std.mem.eql(u8, req.method, "initialize")) {
                    try self.handleInitialize(req);
                } else if (std.mem.eql(u8, req.method, "registerTool")) {
                    try self.registerTool(req.params);
                } else if (std.mem.eql(u8, req.method, "discoverCapabilities")) {
                    try self.discoverCapabilities(req.id);
                } else if (std.mem.eql(u8, req.method, "shutdown")) {
                    try self.handleShutdown(req.id);
                } else {
                    return error.UnsupportedMethod;
                }
            },
            .notification => |notif| {
                if (std.mem.eql(u8, notif.method, "initialized")) {
                    self.state = .ready;
                }
            },
            else => return error.InvalidMessageType,
        }
    }

    /// Handle initialize request
    fn handleInitialize(self: *@This(), req: jsonrpc.Request) !void {
        self.state = .initializing;

        var response = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        try response.object.put("jsonrpc", std.json.Value{ .string = constants.JSON_RPC_VERSION });
        try response.object.put("id", req.id orelse std.json.Value{ .integer = 0 });

        var result = std.json.ObjectMap.init(self.allocator);
        try result.put("protocolVersion", std.json.Value{ .string = PROTOCOL_VERSION });

        var server_info = std.json.ObjectMap.init(self.allocator);
        try server_info.put("name", std.json.Value{ .string = "mcp-zig-session" });
        try server_info.put("version", std.json.Value{ .string = "1.0.0" });
        try result.put("serverInfo", std.json.Value{ .object = server_info });

        try response.object.put("result", std.json.Value{ .object = result });

        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        try std.json.stringify(response, .{}, buffer.writer());
        try self.connection.writer.writeAll(buffer.items);
    }

    /// Handle shutdown request
    fn handleShutdown(self: *@This(), id: ?jsonrpc.Id) !void {
        self.state = .shutdown;

        var response = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        try response.object.put("jsonrpc", std.json.Value{ .string = constants.JSON_RPC_VERSION });
        if (id) |id_val| {
            try response.object.put("id", id_val);
        } else {
            try response.object.put("id", std.json.Value{ .integer = 0 });
        }
        try response.object.put("result", std.json.Value{ .null = {} });

        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        try std.json.stringify(response, .{}, buffer.writer());
        try self.connection.writer.writeAll(buffer.items);
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
        _ = id;
        // Build server capabilities response
        var caps = std.StringHashMap(bool).init(self.allocator);
        defer caps.deinit();

        // Tools capability
        try caps.put("tools", true);
        try caps.put("tools.listChanged", true);

        // Resources capability (if resources are registered)
        if (self.resources.count() > 0) {
            try caps.put("resources", true);
            try caps.put("resources.listChanged", true);
        }

        // Store in session capabilities
        var it = caps.iterator();
        while (it.next()) |entry| {
            try self.capabilities.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    /// Get server capabilities as a summary
    pub fn getCapabilitiesSummary(self: *@This()) struct { tools: bool, resources: bool, prompts: bool } {
        return .{
            .tools = self.tools.count() > 0,
            .resources = self.resources.count() > 0,
            .prompts = false, // Can be extended when prompts are added to session
        };
    }

    /// Get session information
    pub fn getSessionInfo(self: *@This()) struct { id: u32, state: ServerState, tool_count: usize, resource_count: usize } {
        return .{
            .id = self.session_id,
            .state = self.state,
            .tool_count = self.tools.count(),
            .resource_count = self.resources.count(),
        };
    }

    /// Check if session is ready to process requests
    pub fn isReady(self: *@This()) bool {
        return self.state == .ready;
    }

    /// Clean up session resources
    pub fn deinit(self: *@This()) void {
        self.tools.deinit();
        self.resources.deinit();
        self.capabilities.deinit();
    }
};
