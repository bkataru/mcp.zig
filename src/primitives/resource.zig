const std = @import("std");

/// Represents a resource that can be accessed by tools
pub const Resource = struct {
    uri: []const u8,
    data: ?[]const u8,
    metadata: std.StringHashMap([]const u8),

    /// Initialize a new resource
    pub fn init(allocator: std.mem.Allocator, uri: []const u8) !@This() {
        return .{
            .uri = uri,
            .data = null,
            .metadata = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Free resource memory
    pub fn deinit(self: *@This()) void {
        self.metadata.deinit();
    }
};
