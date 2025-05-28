const std = @import("std");

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
};

/// JSON-RPC 2.0 error codes and messages
pub const JsonRpcErrorCode = struct {
    pub const PARSE_ERROR = -32700;
    pub const INVALID_REQUEST = -32600;
    pub const METHOD_NOT_FOUND = -32601;
    pub const INVALID_PARAMS = -32602;
    pub const INTERNAL_ERROR = -32603;
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
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{
            .code = json_rpc_error.code,
            .message = json_rpc_error.message,
            .data = json_rpc_error.data,
        },
    };

    return try std.json.stringifyAlloc(allocator, response, .{});
}

/// Create error response with custom message
pub fn createErrorResponseWithMessage(
    id: ?std.json.Value,
    code: i32,
    message: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const response = .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{
            .code = code,
            .message = message,
        },
    };

    return try std.json.stringifyAlloc(allocator, response, .{});
}

/// Validate JSON-RPC request structure
pub fn validateJsonRpcRequest(request: std.json.Value) McpError!void {
    const obj = request.object;

    // Check jsonrpc version
    const jsonrpc = obj.get("jsonrpc") orelse return error.MissingField;
    if (!std.mem.eql(u8, jsonrpc.string, "2.0")) {
        return error.InvalidRequest;
    }

    // Check method exists
    const method = obj.get("method") orelse return error.MissingField;
    if (method.string.len == 0) {
        return error.InvalidRequest;
    }

    // ID is optional for notifications
}
