//! MCP Protocol Types
//!
//! Type definitions for the Model Context Protocol (MCP) specification.
//! Based on official schema: https://github.com/modelcontextprotocol/modelcontextprotocol/tree/main/schema
//!
//! These types can be automatically serialized/deserialized with std.json.

const std = @import("std");
const constants = @import("constants.zig");
const Allocator = std.mem.Allocator;

// ==================== Common Types ====================

/// Implementation info (client or server)
pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
};

/// Role in a conversation
pub const Role = enum {
    user,
    assistant,
};

// ==================== Capabilities ====================

/// Client capabilities advertised during initialization
pub const ClientCapabilities = struct {
    roots: ?struct {
        listChanged: bool = false,
    } = null,
    sampling: ?std.json.Value = null,
    experimental: ?std.json.Value = null,
};

/// Server capabilities advertised during initialization
pub const ServerCapabilities = struct {
    completions: ?std.json.Value = null,
    experimental: ?std.json.Value = null,
    logging: ?std.json.Value = null,
    prompts: ?struct {
        listChanged: bool = false,
    } = null,
    resources: ?struct {
        listChanged: bool = false,
        subscribe: bool = false,
    } = null,
    tools: ?struct {
        listChanged: bool = false,
    } = null,
};

// ==================== Initialize ====================

/// Parameters for initialize request
pub const InitializeParams = struct {
    protocolVersion: []const u8,
    capabilities: ClientCapabilities,
    clientInfo: Implementation,
};

/// Result of initialize request
pub const InitializeResult = struct {
    protocolVersion: []const u8 = constants.MCP_PROTOCOL_VERSION,
    capabilities: ServerCapabilities,
    serverInfo: Implementation,
    instructions: ?[]const u8 = null,
    _meta: ?std.json.Value = null,
};

/// Parameters for initialized notification
pub const InitializedParams = struct {
    _meta: ?std.json.Value = null,
};

// ==================== Tools ====================

/// Input schema for a tool (JSON Schema subset)
pub const InputSchema = struct {
    type: []const u8 = "object",
    properties: ?std.json.Value = null,
    required: ?[]const []const u8 = null,
    description: ?[]const u8 = null,
};

/// Tool annotations describing behavior
pub const ToolAnnotations = struct {
    destructiveHint: bool = false,
    idempotentHint: bool = false,
    openWorldHint: bool = false,
    readOnlyHint: bool = false,
    title: ?[]const u8 = null,
};

/// Tool definition
pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    inputSchema: InputSchema = .{},
    annotations: ?ToolAnnotations = null,
};

/// Parameters for tools/list request
pub const ListToolsParams = struct {
    cursor: ?[]const u8 = null,
};

/// Result of tools/list request
pub const ListToolsResult = struct {
    tools: []const Tool,
    nextCursor: ?[]const u8 = null,
    _meta: ?std.json.Value = null,
};

/// Parameters for tools/call request
pub const CallToolParams = struct {
    name: []const u8,
    arguments: ?std.json.Value = null,
};

/// Content types for tool results
pub const TextContent = struct {
    type: []const u8 = "text",
    text: []const u8,
};

pub const ImageContent = struct {
    type: []const u8 = "image",
    data: []const u8,
    mimeType: []const u8,
};

pub const AudioContent = struct {
    type: []const u8 = "audio",
    data: []const u8,
    mimeType: []const u8,
};

/// Content item (can be text, image, or audio)
pub const Content = union(enum) {
    text: TextContent,
    image: ImageContent,
    audio: AudioContent,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        switch (self) {
            .text => |t| try jws.write(t),
            .image => |i| try jws.write(i),
            .audio => |a| try jws.write(a),
        }
    }
};

/// Result of tools/call request
pub const CallToolResult = struct {
    content: []const Content,
    isError: bool = false,
    _meta: ?std.json.Value = null,
};

// ==================== Resources ====================

/// Resource definition
pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};

/// Resource template with URI pattern
pub const ResourceTemplate = struct {
    uriTemplate: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};

/// Parameters for resources/list request
pub const ListResourcesParams = struct {
    cursor: ?[]const u8 = null,
};

/// Result of resources/list request
pub const ListResourcesResult = struct {
    resources: []const Resource,
    nextCursor: ?[]const u8 = null,
    _meta: ?std.json.Value = null,
};

/// Resource content (text or blob)
pub const ResourceContent = struct {
    uri: []const u8,
    mimeType: ?[]const u8 = null,
    text: ?[]const u8 = null,
    blob: ?[]const u8 = null,
};

/// Parameters for resources/read request
pub const ReadResourceParams = struct {
    uri: []const u8,
};

/// Result of resources/read request
pub const ReadResourceResult = struct {
    contents: []const ResourceContent,
    _meta: ?std.json.Value = null,
};

// ==================== Prompts ====================

/// Prompt argument definition
pub const PromptArgument = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    required: bool = false,
};

/// Prompt definition
pub const Prompt = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    arguments: ?[]const PromptArgument = null,
};

/// Parameters for prompts/list request
pub const ListPromptsParams = struct {
    cursor: ?[]const u8 = null,
};

/// Result of prompts/list request
pub const ListPromptsResult = struct {
    prompts: []const Prompt,
    nextCursor: ?[]const u8 = null,
    _meta: ?std.json.Value = null,
};

/// Message in a prompt result
pub const PromptMessage = struct {
    role: Role,
    content: Content,
};

/// Parameters for prompts/get request
pub const GetPromptParams = struct {
    name: []const u8,
    arguments: ?std.json.Value = null,
};

/// Result of prompts/get request
pub const GetPromptResult = struct {
    description: ?[]const u8 = null,
    messages: []const PromptMessage,
    _meta: ?std.json.Value = null,
};

// ==================== Logging ====================

/// Log levels
pub const LogLevel = enum {
    debug,
    info,
    notice,
    warning,
    @"error",
    critical,
    alert,
    emergency,
};

/// Logging message notification
pub const LoggingMessage = struct {
    level: LogLevel,
    logger: ?[]const u8 = null,
    data: std.json.Value,
};

// ==================== Validation Functions ====================

/// Validate metadata field (_meta) according to MCP spec
/// Metadata must be an object containing only string keys and JSON values
pub fn validateMetadata(meta: ?std.json.Value) error{
    InvalidMetadataType,
    InvalidMetadataKey,
}!void {
    if (meta == null) return;

    const metadata = meta.?;
    if (metadata != .object) {
        return error.InvalidMetadataType;
    }

    var it = metadata.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;

        if (key.len == 0) {
            return error.InvalidMetadataKey;
        }

        for (key) |c| {
            if (c < 32 or c > 126) {
                return error.InvalidMetadataKey;
            }
        }
    }
}

/// Validate icon URI for allowed schemes (data:, https:)
/// Returns error if scheme is not supported or URI is malformed
pub fn validateIconUri(uri: []const u8) error{
    InvalidUriScheme,
    InvalidDataUri,
    InvalidHttpsUri,
}!void {
    if (uri.len == 0) return;

    const colon_idx = std.mem.indexOfScalar(u8, uri, ':') orelse return error.InvalidUriScheme;
    const scheme = uri[0..colon_idx];

    if (std.mem.eql(u8, scheme, "data")) {
        return validateDataUri(uri);
    } else if (std.mem.eql(u8, scheme, "https")) {
        return validateHttpsUri(uri);
    } else {
        return error.InvalidUriScheme;
    }
}

/// Validate data: URI format
fn validateDataUri(uri: []const u8) error{
    InvalidDataUri,
}!void {
    const comma_idx = std.mem.indexOfScalar(u8, uri, ',') orelse return error.InvalidDataUri;

    if (comma_idx < 6) {
        return error.InvalidDataUri;
    }

    const mime_type = uri[5..comma_idx];

    if (mime_type.len == 0) {
        return error.InvalidDataUri;
    }

    if (std.mem.indexOfScalar(u8, mime_type, ';') != null) {
        const semicolon_idx = std.mem.indexOfScalar(u8, mime_type, ';') orelse return error.InvalidDataUri;
        const encoding = mime_type[semicolon_idx + 1 ..];

        if (!std.mem.eql(u8, encoding, "base64")) {
            return error.InvalidDataUri;
        }
    }

    return;
}

/// Validate https: URI format
fn validateHttpsUri(uri: []const u8) error{
    InvalidHttpsUri,
}!void {
    const after_scheme = uri[6..];

    if (after_scheme.len < 2) {
        return error.InvalidHttpsUri;
    }

    if (!std.mem.eql(u8, after_scheme[0..2], "//")) {
        return error.InvalidHttpsUri;
    }

    const slash_idx = std.mem.indexOfScalarPos(u8, after_scheme, 2, '/') orelse after_scheme.len;

    if (slash_idx == 2) {
        return error.InvalidHttpsUri;
    }

    const host = after_scheme[2..slash_idx];

    if (host.len == 0) {
        return error.InvalidHttpsUri;
    }

    for (host) |c| {
        if (c == '/' or c == '?' or c == '#' or c < 33 or c > 126) {
            return error.InvalidHttpsUri;
        }
    }

    return;
}

// ==================== Helper Functions ====================

/// Create a text content item
pub fn textContent(text: []const u8) Content {
    return .{ .text = .{ .text = text } };
}

/// Create a simple tool with no parameters
pub fn simpleTool(name: []const u8, description: []const u8) Tool {
    return .{
        .name = name,
        .description = description,
        .inputSchema = .{},
    };
}

// ==================== Tests ====================

test "Tool serialization" {
    const tool = simpleTool("test", "A test tool");
    try std.testing.expectEqualStrings("test", tool.name);
    try std.testing.expectEqualStrings("A test tool", tool.description.?);
}

test "Content union" {
    const content = textContent("Hello, world!");
    try std.testing.expectEqualStrings("Hello, world!", content.text.text);
}

test "validateMetadata - valid object" {
    const allocator = std.testing.allocator;
    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();
    try obj.put("key1", std.json.Value{ .string = "value1" });
    try obj.put("key2", std.json.Value{ .integer = 42 });

    const metadata = std.json.Value{ .object = obj };
    try validateMetadata(metadata);
}

test "validateMetadata - null passes" {
    try validateMetadata(null);
}

test "validateMetadata - non-object fails" {
    const metadata = std.json.Value{ .string = "not an object" };
    try std.testing.expectError(error.InvalidMetadataType, validateMetadata(metadata));
}

test "validateMetadata - empty key fails" {
    const allocator = std.testing.allocator;
    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();
    try obj.put("", std.json.Value{ .string = "value" });

    const metadata = std.json.Value{ .object = obj };
    try std.testing.expectError(error.InvalidMetadataKey, validateMetadata(metadata));
}

test "validateIconUri - valid data URI" {
    try validateIconUri("data:image/png;base64,iVBORw0KGgo=");
}

test "validateIconUri - valid https URI" {
    try validateIconUri("https://example.com/icon.png");
}

test "validateIconUri - https with port" {
    try validateIconUri("https://example.com:8080/icon.png");
}

test "validateIconUri - https with path" {
    try validateIconUri("https://example.com/path/to/icon.png");
}

test "validateIconUri - invalid scheme" {
    try std.testing.expectError(error.InvalidUriScheme, validateIconUri("http://example.com/icon.png"));
    try std.testing.expectError(error.InvalidUriScheme, validateIconUri("file:///icon.png"));
}

test "validateIconUri - invalid data URI" {
    try std.testing.expectError(error.InvalidDataUri, validateIconUri("data:"));
    try std.testing.expectError(error.InvalidDataUri, validateIconUri("data:invalid"));
}

test "validateIconUri - invalid https URI" {
    try std.testing.expectError(error.InvalidHttpsUri, validateIconUri("https:"));
    try std.testing.expectError(error.InvalidHttpsUri, validateIconUri("https:/"));
    try std.testing.expectError(error.InvalidHttpsUri, validateIconUri("https:example.com"));
}
