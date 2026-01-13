const std = @import("std");
const constants = @import("constants.zig");
const U8ArrayList = std.array_list.AlignedManaged(u8, null);

/// MCP-specific error types
pub const McpError = error{
    ParseError,
    InvalidRequest,
    MethodNotFound,
    InvalidParams,
    InternalError,
    ServerError,
    UnknownTool,
    SecurityViolation,
    TimeoutError,
    ConnectionError,
    UnsupportedVersion,
    MissingField,
    InvalidToolName,
    ToolExecutionFailed,
    ResourceNotFound,
};

// Re-export error codes from json_utils for consistency
pub const JsonRpcErrorCode = struct {
    pub const PARSE_ERROR = @import("json_utils.zig").ErrorCodes.parse_error;
    pub const INVALID_REQUEST = @import("json_utils.zig").ErrorCodes.invalid_request;
    pub const METHOD_NOT_FOUND = @import("json_utils.zig").ErrorCodes.method_not_found;
    pub const INVALID_PARAMS = @import("json_utils.zig").ErrorCodes.invalid_params;
    pub const INTERNAL_ERROR = @import("json_utils.zig").ErrorCodes.internal_error;
    pub const SERVER_NOT_INITIALIZED = @import("json_utils.zig").ErrorCodes.server_not_initialized;
    pub const UNKNOWN_PROTOCOL_VERSION = @import("json_utils.zig").ErrorCodes.unknown_protocol_version;
    pub const UNKNOWN_TOOL = @import("json_utils.zig").ErrorCodes.unknown_tool;
    pub const SERVER_ERROR = -32000;
    pub const SECURITY_VIOLATION = -32001;
    pub const TOOL_ERROR = -32002;
};

/// JSON-RPC error object structure
pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,

    pub const ParseError = JsonRpcError{
        .code = JsonRpcErrorCode.PARSE_ERROR,
        .message = "Parse error - Invalid JSON was received",
    };

    pub const InvalidRequest = JsonRpcError{
        .code = JsonRpcErrorCode.INVALID_REQUEST,
        .message = "Invalid Request - The JSON sent is not a valid Request object",
    };

    pub const MethodNotFound = JsonRpcError{
        .code = JsonRpcErrorCode.METHOD_NOT_FOUND,
        .message = "Method not found - The method does not exist",
    };

    pub const InvalidParams = JsonRpcError{
        .code = JsonRpcErrorCode.INVALID_PARAMS,
        .message = "Invalid params - Invalid method parameter(s)",
    };

    pub const InternalError = JsonRpcError{
        .code = JsonRpcErrorCode.INTERNAL_ERROR,
        .message = "Internal error - Internal JSON-RPC error",
    };

    pub const ServerError = JsonRpcError{
        .code = JsonRpcErrorCode.SERVER_ERROR,
        .message = "Server error - MCP server error",
    };

    pub const SecurityViolation = JsonRpcError{
        .code = JsonRpcErrorCode.SECURITY_VIOLATION,
        .message = "Security violation - Operation not permitted",
    };

    pub const ToolError = JsonRpcError{
        .code = JsonRpcErrorCode.TOOL_ERROR,
        .message = "Tool execution error",
    };

    /// Convert MCP error to appropriate JSON-RPC error
    pub fn fromMcpError(err: McpError) JsonRpcError {
        return switch (err) {
            error.ParseError => ParseError,
            error.InvalidRequest => InvalidRequest,
            error.MethodNotFound, error.UnknownTool => MethodNotFound,
            error.InvalidParams, error.MissingField, error.InvalidToolName => InvalidParams,
            error.SecurityViolation => SecurityViolation,
            error.ToolExecutionFailed => ToolError,
            error.InternalError, error.TimeoutError, error.ConnectionError => InternalError,
            else => ServerError,
        };
    }

    /// Convert any error to JSON-RPC error
    pub fn fromError(err: anyerror) JsonRpcError {
        return switch (err) {
            error.OutOfMemory => InternalError,
            error.InvalidCharacter, error.UnexpectedToken => ParseError,
            error.AccessDenied => SecurityViolation,
            else => if (@errorReturnTrace()) |trace| blk: {
                std.log.err("Unexpected error: {any} at {any}", .{ err, trace });
                break :blk ServerError;
            } else ServerError,
        };
    }
};

/// Create standardized error response
pub fn createErrorResponse(
    id: ?std.json.Value,
    err: anyerror,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const json_rpc_error = switch (@TypeOf(err)) {
        McpError => JsonRpcError.fromMcpError(err),
        else => JsonRpcError.fromError(err),
    };

    const response = .{
        .jsonrpc = constants.JSON_RPC_VERSION,
        .id = id,
        .@"error" = .{
            .code = json_rpc_error.code,
            .message = json_rpc_error.message,
            .data = json_rpc_error.data,
        },
    };

    return try @import("json_utils.zig").jsonStringifyAlloc(allocator, response);
}

/// Create error response with custom message
pub fn createErrorResponseWithMessage(
    id: ?std.json.Value,
    code: i32,
    message: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const response = .{
        .jsonrpc = constants.JSON_RPC_VERSION,
        .id = id,
        .@"error" = .{
            .code = code,
            .message = message,
        },
    };

    return try @import("json_utils.zig").jsonStringifyAlloc(allocator, response);
}

/// Validate JSON-RPC request structure
pub fn validateJsonRpcRequest(request: std.json.Value) McpError!void {
    const obj = request.object;

    // Check jsonrpc version
    const jsonrpc = obj.get("jsonrpc") orelse return error.MissingField;
    if (!std.mem.eql(u8, jsonrpc.string, constants.JSON_RPC_VERSION)) {
        return error.InvalidRequest;
    }

    // Check method exists
    const method = obj.get("method") orelse return error.MissingField;
    if (method.string.len == 0) {
        return error.InvalidRequest;
    }

    // ID is optional for notifications
}

/// Error context for providing detailed information
pub const ErrorContext = struct {
    error_code: i32,
    error_message: []const u8,
    method: ?[]const u8 = null,
    details: ?std.json.Value = null,
    timestamp: i64,
    request_id: ?std.json.Value = null,
};

/// Create error context with current timestamp
pub fn createErrorContext(error_code: i32, error_message: []const u8, method: ?[]const u8, request_id: ?std.json.Value) ErrorContext {
    return .{
        .error_code = error_code,
        .error_message = error_message,
        .method = method,
        .request_id = request_id,
        .timestamp = std.time.timestamp(),
        .details = null,
    };
}

/// Detailed error with context and suggestions
pub const DetailedError = struct {
    context: ErrorContext,
    cause: ?McpError = null,
    suggestion: ?[]const u8 = null,

    /// Format error as a human-readable message
    pub fn format(self: DetailedError, allocator: std.mem.Allocator) ![]const u8 {
        var result = U8ArrayList.init(allocator);

        try result.writer().print("Error {d}: {s}", .{ self.context.error_code, self.context.error_message });
        if (self.context.method) |method| {
            try result.writer().print(" (method: {s})", .{method});
        }
        if (self.cause) |cause| {
            try result.writer().print("\nCause: {any}", .{cause});
        }
        if (self.suggestion) |sugg| {
            try result.writer().print("\nSuggestion: {s}", .{sugg});
        }

        return result.toOwnedSlice();
    }

    /// Create detailed error from simple error
    pub fn fromError(err: McpError, method: ?[]const u8, request_id: ?std.json.Value) DetailedError {
        _ = JsonRpcError.fromMcpError(err);

        const context = createErrorContext(0, "error", method, request_id);

        return .{
            .context = context,
            .cause = err,
            .suggestion = switch (err) {
                error.UnknownTool => "Call tools/list to see available tools",
                error.InvalidParams => "Check the tool's input schema",
                error.ResourceNotFound => "Verify the resource exists",
                error.ToolExecutionFailed => "Check tool implementation and logs",
                else => null,
            },
        };
    }
};

// ==================== Tests ====================

test "createErrorContext" {
    const context = createErrorContext(-32601, "Method not found", "testMethod", std.json.Value{ .integer = 1 });

    try std.testing.expectEqual(@as(i32, -32601), context.error_code);
    try std.testing.expectEqualStrings("Method not found", context.error_message);
    try std.testing.expectEqualStrings("testMethod", context.method.?);
}

test "DetailedError format" {
    const allocator = std.testing.allocator;
    const detailed = DetailedError.fromError(error.UnknownTool, "callTool", std.json.Value{ .integer = 1 });

    const formatted = try detailed.format(allocator);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "UnknownTool") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Suggestion") != null);
}
