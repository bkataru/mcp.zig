//! prompts_example.zig - MCP server with prompt templates
//!
//! This example demonstrates:
//! - Prompt registration with arguments
//! - Dynamic prompt generation
//! - Role-based message content
//!
//! Run with: zig run examples/prompts_example.zig

const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== MCP Prompts Server ===\n", .{});
    std.debug.print("Starting MCP server with prompt templates...\n\n", .{});

    var prompts = mcp.primitives.PromptRegistry.init(allocator);
    defer prompts.deinit();

    try prompts.register(.{
        .name = "greeting",
        .description = "Generate a personalized greeting",
        .arguments = &[_]mcp.primitives.PromptArgument{
            .{ .name = "name", .description = "Person's name", .required = true },
            .{ .name = "style", .description = "Greeting style (formal, casual, enthusiastic)", .required = false },
        },
        .handler = greetingHandler,
    });

    try prompts.register(.{
        .name = "summarize",
        .description = "Create a summary of the provided text",
        .arguments = &[_]mcp.primitives.PromptArgument{
            .{ .name = "text", .description = "Text to summarize", .required = true },
            .{ .name = "length", .description = "Summary length (short, medium, long)", .required = false },
        },
        .handler = summarizeHandler,
    });

    try prompts.register(.{
        .name = "code_review",
        .description = "Generate a code review prompt",
        .arguments = &[_]mcp.primitives.PromptArgument{
            .{ .name = "language", .description = "Programming language", .required = true },
            .{ .name = "focus", .description = "Review focus (correctness, performance, style, security)", .required = false },
        },
        .handler = codeReviewHandler,
    });

    try prompts.register(.{
        .name = "translate",
        .description = "Create a translation prompt",
        .arguments = &[_]mcp.primitives.PromptArgument{
            .{ .name = "text", .description = "Text to translate", .required = true },
            .{ .name = "target_language", .description = "Target language", .required = true },
        },
        .handler = translateHandler,
    });

    std.debug.print("Registered prompts:\n", .{});
    std.debug.print("  - greeting (name, style)\n", .{});
    std.debug.print("  - summarize (text, length)\n", .{});
    std.debug.print("  - code_review (language, focus)\n", .{});
    std.debug.print("  - translate (text, target_language)\n", .{});
    std.debug.print("\nServer is ready. Waiting for MCP client connections...\n", .{});

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    while (true) {
        const message = try mcp.readContentLengthFrame(allocator, stdin) catch {
            break;
        };
        defer allocator.free(message);

        if (message.len == 0) continue;

        const response = try handlePromptRequest(allocator, &prompts, message);
        defer allocator.free(response);

        if (response.len > 0) {
            try mcp.writeContentLengthFrame(stdout, response);
        }
    }
}

fn getArgString(params: std.json.Value, key: []const u8) ?[]const u8 {
    if (params != .object) return null;
    const val = params.object.get(key) orelse return null;
    if (val == .string) return val.string;
    return null;
}

fn greetingHandler(_: std.mem.Allocator, args: ?std.json.Value) !mcp.primitives.PromptResult {
    const name = getArgString(args orelse .null, "name") orelse "World";
    const style = getArgString(args orelse .null, "style") orelse "casual";

    const message = switch (style[0]) {
        'f', 'F' => blk: {
            break :blk std.fmt.allocPrint(std.testing.allocator, "Good day, {s}. I hope this message finds you well.", .{name}) catch "Hello";
        },
        'e', 'E' => blk: {
            break :blk std.fmt.allocPrint(std.testing.allocator, "Hey there, {s}! Welcome! 🎉 How's your day going?", .{name}) catch "Hello";
        },
        else => blk: {
            break :blk std.fmt.allocPrint(std.testing.allocator, "Hi {s}! Nice to meet you.", .{name}) catch "Hello";
        },
    };
    defer std.testing.allocator.free(message);

    return .{
        .description = "Personalized greeting",
        .messages = &[_]mcp.primitives.PromptMessage{
            .{ .role = "user", .content = message },
        },
    };
}

fn summarizeHandler(_: std.mem.Allocator, args: ?std.json.Value) !mcp.primitives.PromptResult {
    const text = getArgString(args orelse .null, "text") orelse "[No text provided]";
    const length = getArgString(args orelse .null, "length") orelse "medium";

    const prefix = switch (length[0]) {
        's', 'S' => "Brief summary:",
        'l', 'L' => "Detailed summary with all key points:",
        else => "Summary:",
    };

    const content = std.fmt.allocPrint(std.testing.allocator, "{s}\n\n{s}\n\nPlease provide a {s} summary of the above text.", .{ prefix, text, length }) catch "Please summarize";
    defer std.testing.allocator.free(content);

    return .{
        .description = std.fmt.allocPrint(std.testing.allocator, "{s} summary", .{length}) catch "Summary",
        .messages = &[_]mcp.primitives.PromptMessage{
            .{ .role = "user", .content = content },
        },
    };
}

fn codeReviewHandler(_: std.mem.Allocator, args: ?std.json.Value) !mcp.primitives.PromptResult {
    const language = getArgString(args orelse .null, "language") orelse "unknown";
    const focus = getArgString(args orelse .null, "focus") orelse "general";

    const content = std.fmt.allocPrint(std.testing.allocator,
        \\Please review the following {s} code.
        \\Focus areas: {s}
        \\
        \\Code:
        \\[Insert code here]
        \\
        \\Provide a thorough review covering:
        \\- Correctness and potential bugs
        \\- {s}-specific best practices
        \\- Performance considerations
        \\- Security implications
        \\- Code style and readability
    , .{ language, focus, language }) catch "Code review";
    defer std.testing.allocator.free(content);

    return .{
        .description = std.fmt.allocPrint(std.testing.allocator, "{s} code review focusing on {s}", .{ language, focus }) catch "Code review",
        .messages = &[_]mcp.primitives.PromptMessage{
            .{ .role = "user", .content = content },
        },
    };
}

fn translateHandler(_: std.mem.Allocator, args: ?std.json.Value) !mcp.primitives.PromptResult {
    const text = getArgString(args orelse .null, "text") orelse "[No text provided]";
    const target = getArgString(args orelse .null, "target_language") orelse "Spanish";

    const content = std.fmt.allocPrint(std.testing.allocator,
        \\Please translate the following text to {s}.
        \\
        \\Original text:
        \\{s}
        \\
        \\Translation:
    , .{ target, text }) catch "Translation";
    defer std.testing.allocator.free(content);

    return .{
        .description = std.fmt.allocPrint(std.testing.allocator, "Translation to {s}", .{target}) catch "Translation",
        .messages = &[_]mcp.primitives.PromptMessage{
            .{ .role = "user", .content = content },
        },
    };
}

fn handlePromptRequest(allocator: std.mem.Allocator, prompts: *mcp.primitives.PromptRegistry, request_str: []const u8) ![]const u8 {
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

    if (std.mem.eql(u8, method.string, "prompts/list")) {
        return try handlePromptsList(allocator, prompts, id);
    } else if (std.mem.eql(u8, method.string, "prompts/get")) {
        return try handlePromptsGet(allocator, prompts, params, id);
    }

    return try createErrorResponse(allocator, id, -32601, "Method not found");
}

fn handlePromptsList(allocator: std.mem.Allocator, prompts: *mcp.primitives.PromptRegistry, id: ?std.json.Value) ![]const u8 {
    var prompts_array = std.json.Array.init(allocator);
    errdefer prompts_array.deinit(allocator);

    var it = prompts.prompts.valueIterator();
    while (it.next()) |prompt| {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("name", std.json.Value{ .string = prompt.name });
        if (prompt.description) |desc| {
            try obj.put("description", std.json.Value{ .string = desc });
        }
        if (prompt.arguments) |args| {
            var args_array = std.json.Array.init(allocator);
            for (args) |arg| {
                var arg_obj = std.json.ObjectMap.init(allocator);
                try arg_obj.put("name", std.json.Value{ .string = arg.name });
                if (arg.description) |ad| {
                    try arg_obj.put("description", std.json.Value{ .string = ad });
                }
                try arg_obj.put("required", std.json.Value{ .bool = arg.required });
                try args_array.append(std.json.Value{ .object = arg_obj });
            }
            const args_slice = try args_array.toOwnedSlice(allocator);
            try obj.put("arguments", std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, args_slice) });
        }
        try prompts_array.append(std.json.Value{ .object = obj });
    }

    var result = std.json.ObjectMap.init(allocator);
    const slice = try prompts_array.toOwnedSlice(allocator);
    try result.put("prompts", std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, slice) });

    return try createSuccessResponse(allocator, id, std.json.Value{ .object = result });
}

fn handlePromptsGet(allocator: std.mem.Allocator, prompts: *mcp.primitives.PromptRegistry, params: ?std.json.Value, id: ?std.json.Value) ![]const u8 {
    const name = if (params) |p| blk: {
        if (p != .object) break :blk null;
        const name_val = p.object.get("name");
        if (name_val) |nv| {
            if (nv == .string) break :blk nv.string;
        }
        break :blk null;
    } else null;

    if (name == null) {
        return try createErrorResponse(allocator, id, -32602, "Missing name parameter");
    }

    const result = prompts.execute(name, params) catch {
        return try createErrorResponse(allocator, id, -32602, "Prompt not found");
    };

    var messages_array = std.json.Array.init(allocator);
    errdefer messages_array.deinit(allocator);

    for (result.messages) |msg| {
        var msg_obj = std.json.ObjectMap.init(allocator);
        try msg_obj.put("role", std.json.Value{ .string = msg.role });
        try msg_obj.put("content", std.json.Value{ .string = msg.content });
        try messages_array.append(std.json.Value{ .object = msg_obj });
    }

    var response_obj = std.json.ObjectMap.init(allocator);
    if (result.description) |desc| {
        try response_obj.put("description", std.json.Value{ .string = desc });
    }
    const messages_slice = try messages_array.toOwnedSlice(allocator);
    try response_obj.put("messages", std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, messages_slice) });

    return try createSuccessResponse(allocator, id, std.json.Value{ .object = response_obj });
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
