const std = @import("std");

/// Handler function type for resources
pub const ResourceHandlerFn = *const fn (allocator: std.mem.Allocator, uri: []const u8) anyerror!ResourceContent;

/// Callback function type for resource update notifications
pub const ResourceUpdateNotificationFn = *const fn (allocator: std.mem.Allocator, uri: []const u8) anyerror!void;

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

/// Subscription tracking for a resource
const Subscription = struct {
    uri: []const u8,
    callback: ResourceUpdateNotificationFn,
};

/// Registry for managing resources
pub const ResourceRegistry = struct {
    allocator: std.mem.Allocator,
    resources: std.StringHashMapUnmanaged(Resource),
    subscriptions: std.ArrayListUnmanaged(Subscription),
    supports_subscriptions: bool = false,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .resources = .{},
            .subscriptions = .{},
        };
    }

    pub fn deinit(self: *@This()) void {
        self.resources.deinit(self.allocator);
        self.subscriptions.deinit(self.allocator);
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
    /// Returns an owned slice that must be freed by the caller using the registry's allocator
    pub fn list(self: *@This()) []Resource {
        var result = std.ArrayListUnmanaged(Resource){};
        var it = self.resources.valueIterator();
        while (it.next()) |res| {
            result.append(self.allocator, res.*) catch continue;
        }
        return result.toOwnedSlice(self.allocator) catch return &[_]Resource{};
    }

    /// Free a slice returned by list()
    pub fn freeList(self: *@This(), slice: []Resource) void {
        self.allocator.free(slice);
    }

    /// Count registered resources
    pub fn count(self: *@This()) usize {
        return self.resources.count();
    }

    /// Subscribe to resource updates
    /// Returns error if resource doesn't exist or subscriptions not supported
    pub fn subscribe(self: *@This(), uri: []const u8, callback: ResourceUpdateNotificationFn) !void {
        if (!self.supports_subscriptions) {
            return error.SubscriptionsNotSupported;
        }
        if (self.resources.get(uri) == null) {
            return error.ResourceNotFound;
        }

        // Check if already subscribed
        for (self.subscriptions.items) |sub| {
            if (std.mem.eql(u8, sub.uri, uri)) {
                return error.AlreadySubscribed;
            }
        }

        try self.subscriptions.append(self.allocator, .{
            .uri = uri,
            .callback = callback,
        });
    }

    /// Unsubscribe from resource updates
    pub fn unsubscribe(self: *@This(), uri: []const u8) !void {
        for (self.subscriptions.items, 0..) |sub, i| {
            if (std.mem.eql(u8, sub.uri, uri)) {
                _ = self.subscriptions.orderedRemove(i);
                return;
            }
        }
        return error.NotSubscribed;
    }

    /// Get subscription count for a resource
    pub fn getSubscriptionCount(self: *@This(), uri: []const u8) usize {
        var subscription_count: usize = 0;
        for (self.subscriptions.items) |sub| {
            if (std.mem.eql(u8, sub.uri, uri)) {
                subscription_count += 1;
            }
        }
        return subscription_count;
    }

    /// Notify all subscribers of a resource update
    pub fn notifyUpdate(self: *@This(), uri: []const u8) !void {
        for (self.subscriptions.items) |sub| {
            if (std.mem.eql(u8, sub.uri, uri)) {
                try sub.callback(self.allocator, uri);
            }
        }
    }

    /// Count total active subscriptions
    pub fn countSubscriptions(self: *@This()) usize {
        return self.subscriptions.items.len;
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

test "ResourceRegistry subscription tracking" {
    const allocator = std.testing.allocator;
    var registry = ResourceRegistry.init(allocator);
    defer registry.deinit();

    registry.supports_subscriptions = true;

    try registry.register(.{
        .uri = "file:///test.txt",
        .name = "Test File",
    });

    const callback = struct {
        fn notify(_: std.mem.Allocator, _: []const u8) anyerror!void {}
    }.notify;

    // Subscribe to resource
    try registry.subscribe("file:///test.txt", callback);
    try std.testing.expectEqual(@as(usize, 1), registry.countSubscriptions());

    // Duplicate subscription should fail
    try std.testing.expectError(error.AlreadySubscribed, registry.subscribe("file:///test.txt", callback));

    // Unsubscribe
    try registry.unsubscribe("file:///test.txt");
    try std.testing.expectEqual(@as(usize, 0), registry.countSubscriptions());

    // Unsubscribe again should fail
    try std.testing.expectError(error.NotSubscribed, registry.unsubscribe("file:///test.txt"));
}

test "ResourceRegistry subscription to non-existent resource" {
    const allocator = std.testing.allocator;
    var registry = ResourceRegistry.init(allocator);
    defer registry.deinit();

    registry.supports_subscriptions = true;

    const callback = struct {
        fn notify(_: std.mem.Allocator, _: []const u8) anyerror!void {}
    }.notify;

    try std.testing.expectError(error.ResourceNotFound, registry.subscribe("file:///nonexistent.txt", callback));
}

test "ResourceRegistry subscriptions disabled" {
    const allocator = std.testing.allocator;
    var registry = ResourceRegistry.init(allocator);
    defer registry.deinit();

    // subscriptions not enabled by default
    try std.testing.expectEqual(false, registry.supports_subscriptions);

    try registry.register(.{
        .uri = "file:///test.txt",
        .name = "Test File",
    });

    const callback = struct {
        fn notify(_: std.mem.Allocator, _: []const u8) anyerror!void {}
    }.notify;

    try std.testing.expectError(error.SubscriptionsNotSupported, registry.subscribe("file:///test.txt", callback));
}

test "ResourceRegistry get subscription count" {
    const allocator = std.testing.allocator;
    var registry = ResourceRegistry.init(allocator);
    defer registry.deinit();

    registry.supports_subscriptions = true;

    try registry.register(.{
        .uri = "file:///test.txt",
        .name = "Test File",
    });

    const callback = struct {
        fn notify(_: std.mem.Allocator, _: []const u8) anyerror!void {}
    }.notify;

    try std.testing.expectEqual(@as(usize, 0), registry.getSubscriptionCount("file:///test.txt"));

    try registry.subscribe("file:///test.txt", callback);
    try std.testing.expectEqual(@as(usize, 1), registry.getSubscriptionCount("file:///test.txt"));
}

var notify_call_count: usize = 0;

test "ResourceRegistry notifyUpdate" {
    const allocator = std.testing.allocator;
    var registry = ResourceRegistry.init(allocator);
    defer registry.deinit();

    registry.supports_subscriptions = true;

    notify_call_count = 0;

    const callback = struct {
        fn notify(_: std.mem.Allocator, _: []const u8) anyerror!void {
            notify_call_count += 1;
        }
    }.notify;

    try registry.register(.{
        .uri = "file:///test.txt",
        .name = "Test File",
    });

    try registry.subscribe("file:///test.txt", callback);
    try registry.notifyUpdate("file:///test.txt");

    try std.testing.expectEqual(@as(usize, 1), notify_call_count);
}

test "ResourceRegistry unsubscribe" {
    const allocator = std.testing.allocator;
    var registry = ResourceRegistry.init(allocator);
    defer registry.deinit();

    registry.supports_subscriptions = true;

    const callback = struct {
        fn notify(_: std.mem.Allocator, _: []const u8) anyerror!void {}
    }.notify;

    try registry.register(.{
        .uri = "file:///test.txt",
        .name = "Test File",
    });

    try registry.subscribe("file:///test.txt", callback);
    try std.testing.expectEqual(@as(usize, 1), registry.getSubscriptionCount("file:///test.txt"));

    try registry.unsubscribe("file:///test.txt");
    try std.testing.expectEqual(@as(usize, 0), registry.getSubscriptionCount("file:///test.txt"));
}

test "ResourceRegistry multiple subscriptions" {
    const allocator = std.testing.allocator;
    var registry = ResourceRegistry.init(allocator);
    defer registry.deinit();

    registry.supports_subscriptions = true;

    try registry.register(.{
        .uri = "file:///test.txt",
        .name = "Test File",
    });
    try registry.register(.{
        .uri = "file:///other.txt",
        .name = "Other File",
    });

    const callback1 = struct {
        fn notify(_: std.mem.Allocator, _: []const u8) anyerror!void {}
    }.notify;
    const callback2 = struct {
        fn notify(_: std.mem.Allocator, _: []const u8) anyerror!void {}
    }.notify;

    try registry.subscribe("file:///test.txt", callback1);
    try registry.subscribe("file:///other.txt", callback2);
    try std.testing.expectEqual(@as(usize, 1), registry.getSubscriptionCount("file:///test.txt"));
    try std.testing.expectEqual(@as(usize, 1), registry.getSubscriptionCount("file:///other.txt"));
}

test "ResourceRegistry notify all subscribers" {
    const allocator = std.testing.allocator;
    var registry = ResourceRegistry.init(allocator);
    defer registry.deinit();

    registry.supports_subscriptions = true;

    notify_call_count = 0;

    try registry.register(.{
        .uri = "file:///test.txt",
        .name = "Test File",
    });
    try registry.register(.{
        .uri = "file:///other.txt",
        .name = "Other File",
    });

    const callback = struct {
        fn notify(_: std.mem.Allocator, uri: []const u8) anyerror!void {
            if (std.mem.eql(u8, uri, "file:///test.txt")) {
                notify_call_count += 1;
            }
        }
    }.notify;

    try registry.subscribe("file:///test.txt", callback);
    try registry.subscribe("file:///other.txt", callback);
    try registry.notifyUpdate("file:///test.txt");

    try std.testing.expectEqual(@as(usize, 1), notify_call_count);
}

test "ResourceRegistry list resources" {
    const allocator = std.testing.allocator;
    var registry = ResourceRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .uri = "file:///test1.txt",
        .name = "Test 1",
    });
    try registry.register(.{
        .uri = "file:///test2.txt",
        .name = "Test 2",
    });

    const count = registry.count();

    try std.testing.expectEqual(@as(usize, 2), count);
}

test "ResourceRegistry read resource" {
    const allocator = std.testing.allocator;
    var registry = ResourceRegistry.init(allocator);
    defer registry.deinit();

    const handler = struct {
        fn read(_: std.mem.Allocator, _: []const u8) anyerror!ResourceContent {
            return .{
                .uri = "file:///test.txt",
                .mimeType = "text/plain",
                .text = "Hello, world!",
            };
        }
    }.read;

    try registry.register(.{
        .uri = "file:///test.txt",
        .name = "Test File",
        .handler = handler,
    });

    const content = try registry.read("file:///test.txt");

    try std.testing.expectEqualStrings("file:///test.txt", content.uri);
    try std.testing.expectEqualStrings("Hello, world!", content.text.?);
}

test "ResourceRegistry read non-existent" {
    const allocator = std.testing.allocator;
    var registry = ResourceRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expectError(error.ResourceNotFound, registry.read("file:///nonexistent.txt"));
}
