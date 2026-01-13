//! Progress Notification Support for MCP
//!
//! Implements progress/progress_end notifications for long-running operations
//! as specified in the MCP protocol.

const std = @import("std");
const constants = @import("constants.zig");

/// Progress token - can be a string or integer
pub const ProgressToken = union(enum) {
    string: []const u8,
    integer: i64,
};

/// Progress data structure
pub const ProgressData = struct {
    /// Progress value between 0 and 1
    progress: f64,
    /// Optional message describing progress
    message: ?[]const u8 = null,
    /// Optional estimated time remaining in seconds
    eta_seconds: ?f64 = null,
};

/// Complete progress notification data
pub const CompleteProgressData = struct {
    /// Progress token
    token: ProgressToken,
    /// Progress data
    value: ProgressData,
};

/// Progress notification type
pub const ProgressNotification = union(enum) {
    /// Ongoing progress notification
    progress: CompleteProgressData,
    /// Progress completed notification (no value field)
    progress_end: ProgressToken,
};

/// Builder for creating progress notifications
pub const ProgressBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{ .allocator = allocator };
    }

    /// Create a progress notification
    pub fn createProgress(self: @This(), token: ProgressToken, progress: f64, message: ?[]const u8, eta_seconds: ?f64) !std.json.Value {
        var progress_obj = std.json.ObjectMap.init(self.allocator);
        try progress_obj.put("progress", std.json.Value{ .float = progress });
        if (message) |msg| {
            try progress_obj.put("message", std.json.Value{ .string = msg });
        }
        if (eta_seconds) |eta| {
            try progress_obj.put("eta_seconds", std.json.Value{ .float = eta });
        }

        var params = std.json.ObjectMap.init(self.allocator);
        try params.put("token", self.progressTokenToJson(token));
        try params.put("value", std.json.Value{ .object = progress_obj });

        var notification = std.json.ObjectMap.init(self.allocator);
        try notification.put("jsonrpc", std.json.Value{ .string = constants.JSON_RPC_VERSION });
        try notification.put("method", std.json.Value{ .string = "notifications/progress" });
        try notification.put("params", std.json.Value{ .object = params });

        return std.json.Value{ .object = notification };
    }

    /// Create a progress_end notification
    pub fn createProgressEnd(self: @This(), token: ProgressToken) !std.json.Value {
        var params = std.json.ObjectMap.init(self.allocator);
        try params.put("token", self.progressTokenToJson(token));

        var notification = std.json.ObjectMap.init(self.allocator);
        try notification.put("jsonrpc", std.json.Value{ .string = constants.JSON_RPC_VERSION });
        try notification.put("method", std.json.Value{ .string = "notifications/progress/end" });
        try notification.put("params", std.json.Value{ .object = params });

        return std.json.Value{ .object = notification };
    }

    /// Convert progress token to JSON value
    fn progressTokenToJson(_: @This(), token: ProgressToken) std.json.Value {
        return switch (token) {
            .string => |s| std.json.Value{ .string = s },
            .integer => |i| std.json.Value{ .integer = i },
        };
    }

    /// Create a progress token from a JSON value
    pub fn tokenFromJson(_: @This(), value: std.json.Value) !ProgressToken {
        return switch (value) {
            .string => |s| ProgressToken{ .string = s },
            .integer => |i| ProgressToken{ .integer = i },
            else => error.InvalidProgressToken,
        };
    }
};

/// Async notification delivery callback
pub const ProgressNotificationCallback = *const fn (notification_json: []const u8, context: ?*anyopaque) void;

/// Async progress notification delivery mechanism
pub const ProgressNotifier = struct {
    allocator: std.mem.Allocator,
    callback: ?ProgressNotificationCallback,
    context: ?*anyopaque,
    notification_queue: std.ArrayList([]const u8),
    mutex: std.Thread.Mutex,
    running: std.atomic.Value(bool),

    /// Initialize async progress notifier
    pub fn init(allocator: std.mem.Allocator, callback: ?ProgressNotificationCallback, context: ?*anyopaque) !*ProgressNotifier {
        const self = try allocator.create(ProgressNotifier);
        self.* = .{
            .allocator = allocator,
            .callback = callback,
            .context = context,
            .notification_queue = try std.ArrayList([]const u8).initCapacity(allocator, 16),
            .mutex = std.Thread.Mutex{},
            .running = std.atomic.Value(bool).init(false),
        };
        return self;
    }

    /// Start the async notification delivery loop
    pub fn start(self: *@This()) !void {
        if (self.running.load(.acquire)) return;

        self.running.store(true, .release);
        const thread = try std.Thread.spawn(.{}, notificationLoop, .{self});
        thread.detach();
    }

    /// Stop the async notification delivery
    pub fn stop(self: *@This()) void {
        self.running.store(false, .release);
    }

    /// Queue a notification for async delivery
    pub fn notifyAsync(self: *@This(), notification_json: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const owned_json = try self.allocator.dupe(u8, notification_json);
        errdefer self.allocator.free(owned_json);

        try self.notification_queue.append(self.allocator, owned_json);
    }

    /// Deinitialize the notifier
    pub fn deinit(self: *@This()) void {
        self.stop();

        self.mutex.lock();
        for (self.notification_queue.items) |json| {
            self.allocator.free(json);
        }
        self.notification_queue.deinit(self.allocator);
        self.mutex.unlock();

        self.allocator.destroy(self);
    }

    /// Background notification delivery loop
    fn notificationLoop(self: *@This()) void {
        while (self.running.load(.acquire)) {
            self.mutex.lock();
            const notifications = self.notification_queue.items;
            self.notification_queue.clearRetainingCapacity();
            self.mutex.unlock();

            for (notifications) |json| {
                if (self.callback) |cb| {
                    cb(json, self.context);
                }
                self.allocator.free(json);
            }

            // Small delay to prevent busy waiting
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
};

/// Helper type for managing long-running operations with progress
pub const ProgressTracker = struct {
    allocator: std.mem.Allocator,
    token: ProgressToken,
    current_progress: f64 = 0.0,
    start_time: i128,
    notifier: ?*ProgressNotifier,

    /// Initialize a new progress tracker
    pub fn init(allocator: std.mem.Allocator, token: ProgressToken) @This() {
        const now = std.time.nanoTimestamp();
        return .{
            .allocator = allocator,
            .token = token,
            .start_time = now,
            .notifier = null,
        };
    }

    /// Initialize a progress tracker with async notification support
    pub fn initWithNotifier(allocator: std.mem.Allocator, token: ProgressToken, notifier: *ProgressNotifier) @This() {
        const now = std.time.nanoTimestamp();
        return .{
            .allocator = allocator,
            .token = token,
            .start_time = now,
            .notifier = notifier,
        };
    }

    /// Set async notifier for this tracker
    pub fn setNotifier(self: *@This(), notifier: *ProgressNotifier) void {
        self.notifier = notifier;
    }

    /// Update progress and send notification synchronously
    pub fn update(self: *@This(), progress: f64, message: ?[]const u8, writer: std.io.AnyWriter) !void {
        self.current_progress = progress;

        const elapsed_seconds = @as(f64, @floatFromInt(std.time.nanoTimestamp() - self.start_time)) / @as(f64, std.time.ns_per_s);
        const estimated_total = if (progress > 0) elapsed_seconds / progress else null;
        const eta_seconds = if (estimated_total) |total| total - elapsed_seconds else null;

        var builder = ProgressBuilder.init(self.allocator);
        const notification = try builder.createProgress(self.token, progress, message, eta_seconds);

        if (self.notifier) |notifier| {
            // Send notification asynchronously
            var out: std.io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            var stringify: std.json.Stringify = .{
                .writer = &out.writer,
            };
            try stringify.write(notification);
            try notifier.notifyAsync(out.written());
        } else {
            // Send notification synchronously
            var out: std.io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            var stringify: std.json.Stringify = .{
                .writer = &out.writer,
            };
            try stringify.write(notification);
            try writer.writeAll(out.written());
        }
    }

    /// Update progress asynchronously (only works with notifier)
    pub fn updateAsync(self: *@This(), progress: f64, message: ?[]const u8) !void {
        if (self.notifier == null) {
            return error.NoNotifierConfigured;
        }

        self.current_progress = progress;

        const elapsed_seconds = @as(f64, @floatFromInt(std.time.nanoTimestamp() - self.start_time)) / @as(f64, std.time.ns_per_s);
        const estimated_total = if (progress > 0) elapsed_seconds / progress else null;
        const eta_seconds = if (estimated_total) |total| total - elapsed_seconds else null;

        var builder = ProgressBuilder.init(self.allocator);
        const notification = try builder.createProgress(self.token, progress, message, eta_seconds);

        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{
            .writer = &out.writer,
        };
        try stringify.write(notification);
        try self.notifier.?.notifyAsync(out.written());
    }

    /// Complete the operation and send final notification synchronously
    pub fn complete(self: *@This(), writer: std.io.AnyWriter) !void {
        var builder = ProgressBuilder.init(self.allocator);
        const notification = try builder.createProgressEnd(self.token);

        if (self.notifier) |notifier| {
            // Send notification asynchronously
            var out: std.io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            var stringify: std.json.Stringify = .{
                .writer = &out.writer,
            };
            try stringify.write(notification);
            try notifier.notifyAsync(out.written());
        } else {
            // Send notification synchronously
            var out: std.io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            var stringify: std.json.Stringify = .{
                .writer = &out.writer,
            };
            try stringify.write(notification);
            try writer.writeAll(out.written());
        }
    }

    /// Complete the operation asynchronously (only works with notifier)
    pub fn completeAsync(self: *@This()) !void {
        if (self.notifier == null) {
            return error.NoNotifierConfigured;
        }

        var builder = ProgressBuilder.init(self.allocator);
        const notification = try builder.createProgressEnd(self.token);

        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{
            .writer = &out.writer,
        };
        try stringify.write(notification);
        try self.notifier.?.notifyAsync(out.written());
    }

    /// Get current progress percentage (0-100)
    pub fn getPercentage(self: *@This()) f64 {
        return self.current_progress * 100.0;
    }
};

// ==================== Tests ====================

test "ProgressBuilder create progress notification" {
    const allocator = std.testing.allocator;
    var builder = ProgressBuilder.init(allocator);
    const token = ProgressToken{ .integer = 42 };
    var notification = try builder.createProgress(token, 0.5, "Halfway done", 5.0);

    try std.testing.expect(notification == .object);
    const obj = notification.object;
    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqualStrings("notifications/progress", obj.get("method").?.string);

    // Clean up nested objects: value (progress_obj), params, notification
    if (obj.getPtr("params")) |params_ptr| {
        if (params_ptr.* == .object) {
            if (params_ptr.object.getPtr("value")) |value_ptr| {
                if (value_ptr.* == .object) {
                    value_ptr.object.deinit();
                }
            }
            params_ptr.object.deinit();
        }
    }
    // Deinit main notification object
    const notification_mut = @as(*std.json.Value, @ptrCast(&notification));
    notification_mut.object.deinit();
}

test "ProgressBuilder create progress_end notification" {
    const allocator = std.testing.allocator;
    var builder = ProgressBuilder.init(allocator);
    const token = ProgressToken{ .string = "my-token" };
    var notification = try builder.createProgressEnd(token);

    try std.testing.expect(notification == .object);
    const obj = notification.object;
    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqualStrings("notifications/progress/end", obj.get("method").?.string);

    // Clean up nested objects: params, notification
    if (obj.getPtr("params")) |params_ptr| {
        if (params_ptr.* == .object) {
            params_ptr.object.deinit();
        }
    }
    // Deinit main notification object
    const notification_mut = @as(*std.json.Value, @ptrCast(&notification));
    notification_mut.object.deinit();
}

test "ProgressToken from JSON" {
    const allocator = std.testing.allocator;
    var builder = ProgressBuilder.init(allocator);

    const string_token = try builder.tokenFromJson(std.json.Value{ .string = "test-token" });
    try std.testing.expect(string_token == .string);
    try std.testing.expectEqualStrings("test-token", string_token.string);

    const int_token = try builder.tokenFromJson(std.json.Value{ .integer = 123 });
    try std.testing.expect(int_token == .integer);
    try std.testing.expectEqual(@as(i64, 123), int_token.integer);
}

test "ProgressTracker" {
    const allocator = std.testing.allocator;
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 1024);
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator).any();

    const token = ProgressToken{ .integer = 1 };
    var tracker = ProgressTracker.init(allocator, token);

    try std.testing.expectEqual(@as(f64, 0.0), tracker.current_progress);

    // Update progress
    _ = try tracker.update(0.25, "25% complete", writer);
    try std.testing.expectEqual(@as(f64, 0.25), tracker.current_progress);

    try std.testing.expectEqual(@as(f64, 25.0), tracker.getPercentage());

    // Complete
    _ = try tracker.complete(writer);
}

test "ProgressNotifier async delivery" {
    const allocator = std.testing.allocator;

    var notifications_received = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer {
        for (notifications_received.items) |notification| {
            allocator.free(notification);
        }
        notifications_received.deinit(allocator);
    }

    // Callback function to capture notifications
    const callback = struct {
        fn callback(notification_json: []const u8, context: ?*anyopaque) void {
            const list = @as(*std.ArrayList([]const u8), @ptrCast(@alignCast(context.?)));
            const owned = allocator.dupe(u8, notification_json) catch return;
            list.append(allocator, owned) catch return;
        }
    }.callback;

    // Create notifier
    var notifier = try ProgressNotifier.init(allocator, callback, &notifications_received);
    defer notifier.deinit();

    // Start async delivery
    try notifier.start();

    // Create tracker with notifier
    const token = ProgressToken{ .string = "test-async" };
    var tracker = ProgressTracker.initWithNotifier(allocator, token, notifier);

    // Send async progress update
    try tracker.updateAsync(0.5, "Halfway there");

    // Wait a bit for async delivery
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Check that notification was received
    try std.testing.expect(notifications_received.items.len > 0);

    // Verify notification contains expected content
    const notification = notifications_received.items[0];
    try std.testing.expect(std.mem.indexOf(u8, notification, "notifications/progress") != null);
    try std.testing.expect(std.mem.indexOf(u8, notification, "test-async") != null);
    try std.testing.expect(std.mem.indexOf(u8, notification, "0.5") != null);
}

test "ProgressNotifier sync fallback" {
    const allocator = std.testing.allocator;
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 1024);
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator).any();

    // Create tracker without notifier (should use sync delivery)
    const token = ProgressToken{ .string = "test-sync" };
    var tracker = ProgressTracker.init(allocator, token);

    // Update progress synchronously
    try tracker.update(0.75, "75% complete", writer);

    // Verify notification was written to buffer
    const output = buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "notifications/progress") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "test-sync") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "0.75") != null);
}
