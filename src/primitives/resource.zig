const std = @import("std");

/// Handler function type for resources
pub const ResourceHandlerFn = *const fn (allocator: std.mem.Allocator, uri: []const u8) anyerror!ResourceContent;

/// Represents a resource that can be accessed by tools
pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    handler: ?ResourceHandlerFn = null,
};

/// Resource content returned by handlers
pub const ResourceContent = struct {
    uri: []const u8,
    mimeType: ?[]const u8 = null,
    text: ?[]const u8 = null,
    blob: ?[]const u8 = null,
};

/// Registry for managing resources
pub const ResourceRegistry = struct {
    allocator: std.mem.Allocator,
    resources: std.StringHashMapUnmanaged(Resource),

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .resources = .{},
        };
    }

    pub fn deinit(self: *@This()) void {
        self.resources.deinit(self.allocator);
    }

    /// Register a new resource
    pub fn register(self: *@This(), resource: Resource) !void {
        try self.resources.put(self.allocator, resource.uri, resource);
    }

    /// Get a resource by URI
    pub fn get(self: *@This(), uri: []const u8) ?Resource {
        return self.resources.get(uri);
    }

    /// Read resource content
    pub fn read(self: *@This(), uri: []const u8) !ResourceContent {
        const resource = self.resources.get(uri) orelse return error.ResourceNotFound;
        if (resource.handler) |handler| {
            return handler(self.allocator, uri);
        }
        return error.NoHandler;
    }

    /// List all resources
    pub fn list(self: *@This()) []const Resource {
        var result = std.ArrayListUnmanaged(Resource){};
        var it = self.resources.valueIterator();
        while (it.next()) |res| {
            result.append(self.allocator, res.*) catch continue;
        }
        return result.items;
    }

    /// Count registered resources
    pub fn count(self: *@This()) usize {
        return self.resources.count();
    }
};

// ==================== Tests ====================

test "ResourceRegistry basic operations" {
    const allocator = std.testing.allocator;
    var registry = ResourceRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .uri = "file:///test.txt",
        .name = "Test File",
        .description = "A test file",
        .mimeType = "text/plain",
    });

    try std.testing.expectEqual(@as(usize, 1), registry.count());

    const resource = registry.get("file:///test.txt");
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("Test File", resource.?.name);
}
