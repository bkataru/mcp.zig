const std = @import("std");

/// Represents a prompt that can be processed by tools
pub const Prompt = struct {
    text: []const u8,
    context: std.StringHashMap([]const u8),

    /// Create a new prompt with the given text
    pub fn init(allocator: std.mem.Allocator, text: []const u8) !@This() {
        return .{
            .text = text,
            .context = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Free prompt resources
    pub fn deinit(self: *@This()) void {
        self.context.deinit();
    }
};
