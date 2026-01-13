const std = @import("std");
const builtin = @import("builtin");
const tool = @import("../primitives/tool.zig");
const Tool = tool.Tool;

/// Allowed commands for security
const ALLOWED_COMMANDS = [_][]const u8{ "echo", "ls" };

/// CLI tool handler function
fn cliHandler(
    allocator: std.mem.Allocator,
    params: std.StringHashMap([]const u8),
) anyerror![]const u8 {
    const command = params.get("command") orelse return error.MissingParameter;
    const args = params.get("args");

    // Security check - only allow specific commands
    var command_allowed = false;
    for (ALLOWED_COMMANDS) |allowed_cmd| {
        if (std.mem.eql(u8, command, allowed_cmd)) {
            command_allowed = true;
            break;
        }
    }

    if (!command_allowed) {
        return error.SecurityViolation;
    }

    // Build command arguments
    var cmd_args = std.ArrayList([]const u8).init(allocator);
    defer cmd_args.deinit();

    // On Windows, use cmd.exe for built-in commands like echo
    if (builtin.os.tag == .windows) {
        try cmd_args.append("cmd.exe");
        try cmd_args.append("/c");

        // Map ls to dir on Windows
        if (std.mem.eql(u8, command, "ls")) {
            try cmd_args.append("dir");
        } else {
            try cmd_args.append(command);
        }

        if (args) |args_str| {
            // Add arguments as a single string
            try cmd_args.append(args_str);
        }
    } else {
        // Unix-like systems
        try cmd_args.append(command);

        if (args) |args_str| {
            // Simple argument parsing - split by spaces
            var arg_iterator = std.mem.splitScalar(u8, args_str, ' ');
            while (arg_iterator.next()) |arg| {
                if (arg.len > 0) {
                    try cmd_args.append(arg);
                }
            }
        }
    }

    // Execute command using exec which handles output properly
    const exec_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = cmd_args.items,
        .max_output_bytes = 1024 * 1024, // 1MB limit
    }) catch |err| {
        return err;
    };
    defer allocator.free(exec_result.stdout);
    defer allocator.free(exec_result.stderr);

    // Check exit status
    if (exec_result.term != .Exited or exec_result.term.Exited != 0) {
        if (exec_result.stderr.len > 0) {
            // Include stderr in error for debugging
            std.log.err("Command failed: {s}", .{exec_result.stderr});
        }
        return error.CommandFailed;
    }

    // Return owned copy of stdout
    return try allocator.dupe(u8, exec_result.stdout);
}

pub const CLI = struct {
    tool_instance: *Tool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !CLI {
        const tool_instance = try Tool.init(allocator, "cli", "Execute system commands (restricted to echo and ls)", cliHandler);

        try tool_instance.addParameter("command", "string");
        try tool_instance.addParameter("args", "string");

        return CLI{
            .tool_instance = tool_instance,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CLI) void {
        self.tool_instance.parameters.deinit();
        self.allocator.free(self.tool_instance.name);
        self.allocator.free(self.tool_instance.description);
        self.allocator.destroy(self.tool_instance);
    }

    pub fn tool(self: *CLI) *Tool {
        return self.tool_instance;
    }
};

/// Initialize CLI tool for compatibility with existing code
pub fn init(allocator: std.mem.Allocator) !*Tool {
    const tool_instance = try Tool.init(allocator, "cli", "Execute system commands (restricted to echo and ls)", cliHandler);

    try tool_instance.addParameter("command", "string");
    try tool_instance.addParameter("args", "string");

    return tool_instance;
}
