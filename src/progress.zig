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
        _ = token;
        var progress_obj = std.json.ObjectMap.init(self.allocator);
        try progress_obj.put("progress", std.json.Value{ .float = progress });
        if (message) |msg| {
            try progress_obj.put("message", std.json.Value{ .string = msg });
        }
        if (eta_seconds) |eta| {
            try progress_obj.put("eta_seconds", std.json.Value{ .float = eta });
        }

        var notification = std.json.ObjectMap.init(self.allocator);
        try notification.put("jsonrpc", std.json.Value{ .string = constants.JSON_RPC_VERSION });
        try notification.put("method", std.json.Value{ .string = "notifications/progress" });

        var params = std.json.ObjectMap.init(self.allocator);
        try params.put("token", try self.progressTokenToJson(token));
        try params.put("value", std.json.Value{ .object = progress_obj });
        try notification.put("params", std.json.Value{ .object = params });

        return std.json.Value{ .object = notification };
    }

    /// Create a progress_end notification
    pub fn createProgressEnd(self: @This(), token: ProgressToken) !std.json.Value {
        _ = token;
        var notification = std.json.ObjectMap.init(self.allocator);
        try notification.put("jsonrpc", std.json.Value{ .string = constants.JSON_RPC_VERSION });
        try notification.put("method", std.json.Value{ .string = "notifications/progress/end" });

        var params = std.json.ObjectMap.init(self.allocator);
        try params.put("token", try self.progressTokenToJson(token));
        try notification.put("params", std.json.Value{ .object = params });

        return std.json.Value{ .object = notification };
    }

    /// Convert progress token to JSON value
    fn progressTokenToJson(self: @This(), token: ProgressToken) !std.json.Value {
        return switch (token) {
            .string => |s| std.json.Value{ .string = s },
            .integer => |i| std.json.Value{ .integer = i },
        };
    }

    /// Create a progress token from a JSON value
    pub fn tokenFromJson(self: @This(), value: std.json.Value) !ProgressToken {
        return switch (value) {
            .string => |s| ProgressToken{ .string = s },
            .integer => |i| ProgressToken{ .integer = i },
            else => error.InvalidProgressToken,
        };
    }
};

/// Helper type for managing long-running operations with progress
pub const ProgressTracker = struct {
    allocator: std.mem.Allocator,
    token: ProgressToken,
    current_progress: f64 = 0.0,
    start_time: i64,

    /// Initialize a new progress tracker
    pub fn init(allocator: std.mem.Allocator, token: ProgressToken) @This() {
        const now = std.time.nanoTimestamp();
        return .{
            .allocator = allocator,
            .token = token,
            .start_time = now,
        };
    }

    /// Update progress and send notification
    pub fn update(self: *@This(), progress: f64, message: ?[]const u8, writer: std.io.AnyWriter) !void {
        _ = message;
        self.current_progress = progress;

        const elapsed_seconds = @as(f64, @floatFromInt(std.time.nanoTimestamp() - self.start_time)) / @as(f64, std.time.ns_per_s);
        const estimated_total = if (progress > 0) elapsed_seconds / progress else null;
        const eta_seconds = if (estimated_total) |total| total - elapsed_seconds else null;

        var builder = ProgressBuilder.init(self.allocator);
        const notification = try builder.createProgress(self.token, progress, message, eta_seconds);

        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        try std.json.stringify(notification, .{}, buffer.writer());
        try writer.writeAll(buffer.items);
    }

    /// Complete the operation and send final notification
    pub fn complete(self: *@This(), writer: std.io.AnyWriter) !void {
        var builder = ProgressBuilder.init(self.allocator);
        const notification = try builder.createProgressEnd(self.token);

        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        try std.json.stringify(notification, .{}, buffer.writer());
        try writer.writeAll(buffer.items);
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
    const notification = try builder.createProgress(token, 0.5, "Halfway done", 5.0);

    try std.testing.expect(notification == .object);
    const obj = notification.object;
    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqualStrings("notifications/progress", obj.get("method").?.string);
}

test "ProgressBuilder create progress_end notification" {
    const allocator = std.testing.allocator;
    var builder = ProgressBuilder.init(allocator);
    const token = ProgressToken{ .string = "my-token" };
    const notification = try builder.createProgressEnd(token);

    try std.testing.expect(notification == .object);
    const obj = notification.object;
    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqualStrings("notifications/progress/end", obj.get("method").?.string);
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
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer().any();

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
