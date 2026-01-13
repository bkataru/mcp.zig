//! JSON Utilities and Response Builder
//!
//! Consolidated JSON utilities to eliminate code duplication
//! and provide consistent response building patterns.

const std = @import("std");
const constants = @import("constants.zig");

/// Helper to stringify JSON to an allocated slice (Zig 0.15 compatible)
pub fn jsonStringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &out.writer,
    };
    try stringify.write(value);
    return out.toOwnedSlice();
}

/// Response Builder for creating consistent JSON-RPC responses
pub const ResponseBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{ .allocator = allocator };
    }

    /// Create a JSON-RPC success response
    pub fn success(self: @This(), id: ?std.json.Value, result: std.json.Value) ![]const u8 {
        var response_map = std.json.ObjectMap.init(self.allocator);
        try response_map.put("jsonrpc", std.json.Value{ .string = constants.JSON_RPC_VERSION });
        try response_map.put("result", result);

        if (id) |id_val| {
            try response_map.put("id", id_val);
        }

        var out: std.io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        var stringify: std.json.Stringify = .{
            .writer = &out.writer,
        };
        try stringify.write(std.json.Value{ .object = response_map });
        const response = out.toOwnedSlice();
        response_map.deinit();

        return response;
    }

    /// Create a JSON-RPC error response
    pub fn errorResponse(self: @This(), id: ?std.json.Value, error_code: i32, message: []const u8) ![]const u8 {
        var error_obj = std.json.ObjectMap.init(self.allocator);
        try error_obj.put("code", std.json.Value{ .integer = error_code });
        try error_obj.put("message", std.json.Value{ .string = message });

        var response_map = std.json.ObjectMap.init(self.allocator);
        try response_map.put("jsonrpc", std.json.Value{ .string = constants.JSON_RPC_VERSION });
        try response_map.put("error", std.json.Value{ .object = error_obj });

        if (id) |id_val| {
            try response_map.put("id", id_val);
        }

        var out: std.io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        var stringify: std.json.Stringify = .{
            .writer = &out.writer,
        };
        try stringify.write(std.json.Value{ .object = response_map });
        const result = out.toOwnedSlice();

        response_map.deinit();
        error_obj.deinit();

        return result;
    }

    /// Create a tool response with content
    pub fn toolResponse(self: @This(), id: ?std.json.Value, text_content: []const u8, is_error: bool) ![]const u8 {
        var content_array = std.json.Array.init(self.allocator);
        var content_obj = std.json.ObjectMap.init(self.allocator);
        try content_obj.put("type", std.json.Value{ .string = "text" });
        try content_obj.put("text", std.json.Value{ .string = text_content });
        try content_array.append(std.json.Value{ .object = content_obj });

        var result = std.json.ObjectMap.init(self.allocator);
        try result.put("content", std.json.Value{ .array = content_array });

        if (is_error) {
            try result.put("isError", std.json.Value{ .bool = true });
        }

        const response = try self.success(id, std.json.Value{ .object = result });
        result.deinit();
        content_obj.deinit();
        content_array.deinit();

        return response;
    }

    /// Create initialize response
    pub fn initializeResponse(self: @This(), id: ?std.json.Value, capabilities_map: std.json.ObjectMap) ![]const u8 {
        var server_info_map = std.json.ObjectMap.init(self.allocator);
        try server_info_map.put("name", std.json.Value{ .string = "mcp-zig-server" });
        try server_info_map.put("version", std.json.Value{ .string = constants.SERVER_VERSION });

        var result_map = std.json.ObjectMap.init(self.allocator);
        try result_map.put("protocolVersion", std.json.Value{ .string = constants.MCP_PROTOCOL_VERSION });
        try result_map.put("capabilities", std.json.Value{ .object = capabilities_map });
        try result_map.put("serverInfo", std.json.Value{ .object = server_info_map });

        const response = try self.success(id, std.json.Value{ .object = result_map });
        result_map.deinit();
        server_info_map.deinit();

        return response;
    }
};

/// JSON-RPC Error codes
pub const ErrorCodes = struct {
    pub const parse_error = -32700;
    pub const invalid_request = -32600;
    pub const method_not_found = -32601;
    pub const invalid_params = -32602;
    pub const internal_error = -32603;
    pub const server_not_initialized = -32099;
    pub const unknown_protocol_version = -32098;
    pub const unknown_tool = -32097;
};

// ==================== Tests ====================

test "jsonStringifyAlloc with string" {
    const allocator = std.testing.allocator;

    const result = try jsonStringifyAlloc(allocator, std.json.Value{ .string = "test" });
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "test") != null);
}

test "ResponseBuilder errorResponse" {
    const allocator = std.testing.allocator;
    var builder = ResponseBuilder.init(allocator);

    const response = try builder.errorResponse(std.json.Value{ .integer = 1 }, -32601, "Method not found");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "jsonrpc") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Method not found") != null);
}

test "ResponseBuilder toolResponse" {
    const allocator = std.testing.allocator;
    var builder = ResponseBuilder.init(allocator);

    const response = try builder.toolResponse(std.json.Value{ .integer = 1 }, "test result", false);
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "content") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "text") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "test result") != null);
}
