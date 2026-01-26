//! file_server.zig - MCP server providing file resources
//!
//! This example demonstrates:
//! - Resource registration with handlers
//! - Resource templates for dynamic URIs
//! - Reading and serving file content
//!
//! Run with: zig run examples/file_server.zig

const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== MCP File Server ===\n", .{});
    std.debug.print("Starting MCP server with file resources...\n\n", .{});

    var resources = mcp.primitives.ResourceRegistry.init(allocator);
    defer resources.deinit();

    resources.supports_subscriptions = true;

    try resources.register(.{
        .uri = "file:///README.md",
        .name = "Project README",
        .description = "The main README file for the project",
        .mimeType = "text/markdown",
        .handler = readmeHandler,
    });

    try resources.register(.{
        .uri = "file:///package.json",
        .name = "Package Config",
        .description = "Package configuration file",
        .mimeType = "application/json",
        .handler = packageHandler,
    });

    try resources.register(.{
        .uri = "file:///CHANGELOG.md",
        .name = "Changelog",
        .description = "Version history and changes",
        .mimeType = "text/markdown",
        .handler = changelogHandler,
    });

    std.debug.print("Registered resources:\n", .{});
    std.debug.print("  - file:///README.md (Project README)\n", .{});
    std.debug.print("  - file:///package.json (Package Config)\n", .{});
    std.debug.print("  - file:///CHANGELOG.md (Changelog)\n", .{});
    std.debug.print("\nResource subscriptions enabled.\n", .{});
    std.debug.print("Server is ready. Waiting for MCP client connections...\n", .{});

    const stdin_file = std.fs.File.stdin();
    const stdout_file = std.fs.File.stdout();
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var reader = stdin_file.reader(&read_buf);
    var writer = stdout_file.writer(&write_buf);

    while (true) {
        const message = mcp.readContentLengthFrame(allocator, &reader.interface) catch {
            break;
        };
        defer allocator.free(message);

        if (message.len == 0) continue;

        std.debug.print("\nReceived request ({d} bytes)\n", .{message.len});

        const response = handleResourceRequest(allocator, &resources, message) catch continue;
        defer allocator.free(response);

        if (response.len > 0) {
            mcp.writeContentLengthFrame(&writer.interface, response) catch break;
            std.debug.print("Sent response ({d} bytes)\n", .{response.len});
        }
    }
}

fn readmeHandler(_: std.mem.Allocator, uri: []const u8) !mcp.primitives.ResourceContent {
    return .{
        .uri = uri,
        .mimeType = "text/markdown",
        .text = "# MCP.zig\n\nA Zig implementation of the Model Context Protocol.\n\n## Features\n\n- JSON-RPC 2.0 transport\n- Content-Length streaming\n- Tool registration\n- Resource handling\n- Prompt templates\n",
        .blob = null,
    };
}

fn packageHandler(_: std.mem.Allocator, uri: []const u8) !mcp.primitives.ResourceContent {
    return .{
        .uri = uri,
        .mimeType = "application/json",
        .text = "{\n  \"name\": \"mcp-zig\",\n  \"version\": \"0.1.0\",\n  \"description\": \"Zig implementation of MCP\",\n  \"main\": \"src/lib.zig\"\n}",
        .blob = null,
    };
}

fn changelogHandler(_: std.mem.Allocator, uri: []const u8) !mcp.primitives.ResourceContent {
    return .{
        .uri = uri,
        .mimeType = "text/markdown",
        .text = "# Changelog\n\n## v0.1.0\n\n- Initial release\n- Basic MCP protocol support\n- JSON-RPC 2.0 implementation\n- Tool registration and execution\n- Resource handling\n",
        .blob = null,
    };
}

fn handleResourceRequest(allocator: std.mem.Allocator, resources: *mcp.primitives.ResourceRegistry, request_str: []const u8) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, request_str, .{}) catch {
        return try createErrorResponse(allocator, null, -32700, "Parse error");
    };
    defer parsed.deinit();

    const request = parsed.value;
    if (request != .object) {
        return try createErrorResponse(allocator, null, -32600, "Invalid request");
    }

    const method = request.object.get("method") orelse {
        return try createErrorResponse(allocator, null, -32600, "Method not found");
    };

    if (method != .string) {
        return try createErrorResponse(allocator, null, -32600, "Method must be a string");
    }

    const id = request.object.get("id");
    const params = request.object.get("params");

    if (std.mem.eql(u8, method.string, "resources/list")) {
        return try handleResourcesList(allocator, resources, id);
    } else if (std.mem.eql(u8, method.string, "resources/read")) {
        return try handleResourcesRead(allocator, resources, params, id);
    } else if (std.mem.eql(u8, method.string, "resources/subscribe")) {
        return try handleResourcesSubscribe(allocator, resources, params, id);
    } else if (std.mem.eql(u8, method.string, "resources/unsubscribe")) {
        return try handleResourcesUnsubscribe(allocator, resources, params, id);
    }

    return try createErrorResponse(allocator, id, -32601, "Method not found");
}

fn handleResourcesList(allocator: std.mem.Allocator, resources: *mcp.primitives.ResourceRegistry, id: ?std.json.Value) ![]const u8 {
    var resources_array = std.json.Array.init(allocator);
    errdefer resources_array.deinit(allocator);

    var it = resources.resources.valueIterator();
    while (it.next()) |res| {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("uri", std.json.Value{ .string = res.uri });
        try obj.put("name", std.json.Value{ .string = res.name });
        if (res.description) |desc| {
            try obj.put("description", std.json.Value{ .string = desc });
        }
        if (res.mimeType) |mime| {
            try obj.put("mimeType", std.json.Value{ .string = mime });
        }
        try resources_array.append(std.json.Value{ .object = obj });
    }

    var result = std.json.ObjectMap.init(allocator);
    const slice = try resources_array.toOwnedSlice(allocator);
    try result.put("resources", std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, slice) });

    return try createSuccessResponse(allocator, id, std.json.Value{ .object = result });
}

fn handleResourcesRead(allocator: std.mem.Allocator, resources: *mcp.primitives.ResourceRegistry, params: ?std.json.Value, id: ?std.json.Value) ![]const u8 {
    const uri = if (params) |p| blk: {
        if (p != .object) break :blk null;
        const uri_val = p.object.get("uri");
        if (uri_val) |uv| {
            if (uv == .string) break :blk uv.string;
        }
        break :blk null;
    } else null;

    if (uri == null) {
        return try createErrorResponse(allocator, id, -32602, "Missing uri parameter");
    }

    const content = resources.read(uri) catch {
        return try createErrorResponse(allocator, id, -32602, "Resource not found");
    };

    var contents_array = std.json.Array.init(allocator);
    errdefer contents_array.deinit(allocator);

    var content_obj = std.json.ObjectMap.init(allocator);
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
    try contents_array.append(std.json.Value{ .object = content_obj });

    var result = std.json.ObjectMap.init(allocator);
    const slice = try contents_array.toOwnedSlice(allocator);
    try result.put("contents", std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, slice) });

    return try createSuccessResponse(allocator, id, std.json.Value{ .object = result });
}

fn handleResourcesSubscribe(alloc: std.mem.Allocator, resources: *mcp.primitives.ResourceRegistry, params: ?std.json.Value, id: ?std.json.Value) ![]const u8 {
    const uri = if (params) |p| blk: {
        if (p != .object) break :blk null;
        const uri_val = p.object.get("uri");
        if (uri_val) |uv| {
            if (uv == .string) break :blk uv.string;
        }
        break :blk null;
    } else null;

    if (uri == null) {
        return try createErrorResponse(alloc, id, -32602, "Missing uri parameter");
    }

    resources.subscribe(uri, struct {
        fn notify(_: std.mem.Allocator, u: []const u8) !void {
            std.debug.print("Resource updated: {s}\n", .{u});
        }
    }.notify) catch {
        return try createErrorResponse(alloc, id, -32602, "Failed to subscribe");
    };

    return try createSuccessResponse(alloc, id, std.json.Value{ .null = {} });
}

fn handleResourcesUnsubscribe(alloc: std.mem.Allocator, resources: *mcp.primitives.ResourceRegistry, params: ?std.json.Value, id: ?std.json.Value) ![]const u8 {
    const uri = if (params) |p| blk: {
        if (p != .object) break :blk null;
        const uri_val = p.object.get("uri");
        if (uri_val) |uv| {
            if (uv == .string) break :blk uv.string;
        }
        break :blk null;
    } else null;

    if (uri == null) {
        return try createErrorResponse(alloc, id, -32602, "Missing uri parameter");
    }

    resources.unsubscribe(uri) catch {
        return try createErrorResponse(alloc, id, -32602, "Not subscribed");
    };

    return try createSuccessResponse(alloc, id, std.json.Value{ .null = {} });
}

fn createSuccessResponse(allocator: std.mem.Allocator, id: ?std.json.Value, result: std.json.Value) ![]const u8 {
    var response = std.json.ObjectMap.init(allocator);
    try response.put("jsonrpc", std.json.Value{ .string = "2.0" });
    try response.put("result", result);
    if (id) |id_val| {
        try response.put("id", id_val);
    }

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.write(std.json.Value{ .object = response });
    return out.toOwnedSlice();
}

fn createErrorResponse(allocator: std.mem.Allocator, id: ?std.json.Value, code: i32, message: []const u8) ![]const u8 {
    var error_obj = std.json.ObjectMap.init(allocator);
    try error_obj.put("code", std.json.Value{ .integer = code });
    try error_obj.put("message", std.json.Value{ .string = message });

    var response = std.json.ObjectMap.init(allocator);
    try response.put("jsonrpc", std.json.Value{ .string = "2.0" });
    try response.put("error", std.json.Value{ .object = error_obj });
    if (id) |id_val| {
        try response.put("id", id_val);
    }

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.write(std.json.Value{ .object = response });
    return out.toOwnedSlice();
}
