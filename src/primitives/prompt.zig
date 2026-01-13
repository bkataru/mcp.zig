const std = @import("std");

/// Handler function type for prompts
pub const PromptHandlerFn = *const fn (allocator: std.mem.Allocator, arguments: ?std.json.Value) anyerror!PromptResult;

/// Prompt argument definition
pub const PromptArgument = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    required: bool = false,
};

/// Prompt message content
pub const PromptMessage = struct {
    role: []const u8, // "user", "assistant", or "system"
    content: []const u8,
};

/// Result from executing a prompt
pub const PromptResult = struct {
    description: ?[]const u8 = null,
    messages: []const PromptMessage,
};

/// Represents a prompt template
pub const Prompt = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    arguments: ?[]const PromptArgument = null,
    handler: ?PromptHandlerFn = null,
};

/// Registry for managing prompts
pub const PromptRegistry = struct {
    allocator: std.mem.Allocator,
    prompts: std.StringHashMapUnmanaged(Prompt),

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .prompts = .{},
        };
    }

    pub fn deinit(self: *@This()) void {
        self.prompts.deinit(self.allocator);
    }

    /// Register a new prompt
    pub fn register(self: *@This(), prompt: Prompt) !void {
        try self.prompts.put(self.allocator, prompt.name, prompt);
    }

    /// Get a prompt by name
    pub fn get(self: *@This(), name: []const u8) ?Prompt {
        return self.prompts.get(name);
    }

    /// Execute a prompt with arguments
    pub fn execute(self: *@This(), name: []const u8, arguments: ?std.json.Value) !PromptResult {
        const prompt = self.prompts.get(name) orelse return error.PromptNotFound;
        if (prompt.handler) |handler| {
            return handler(self.allocator, arguments);
        }
        return error.NoHandler;
    }

    /// List all prompts
    pub fn list(self: *@This()) []const Prompt {
        var result = std.ArrayListUnmanaged(Prompt){};
        var it = self.prompts.valueIterator();
        while (it.next()) |p| {
            result.append(self.allocator, p.*) catch continue;
        }
        return result.items;
    }

    /// Count registered prompts
    pub fn count(self: *@This()) usize {
        return self.prompts.count();
    }
};

// ==================== Tests ====================

test "PromptRegistry basic operations" {
    const allocator = std.testing.allocator;
    var registry = PromptRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .name = "greeting",
        .description = "A greeting prompt",
        .arguments = &[_]PromptArgument{
            .{ .name = "name", .description = "Name to greet", .required = true },
        },
    });

    try std.testing.expectEqual(@as(usize, 1), registry.count());

    const prompt = registry.get("greeting");
    try std.testing.expect(prompt != null);
    try std.testing.expectEqualStrings("A greeting prompt", prompt.?.description.?);
}
