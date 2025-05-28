const std = @import("std");
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

    try cmd_args.append(command);

    if (args) |args_str| {
        // Simple argument parsing - split by spaces
        var arg_iterator = std.mem.split(u8, args_str, " ");
        while (arg_iterator.next()) |arg| {
            if (arg.len > 0) {
                try cmd_args.append(arg);
            }
        }
    }

    // Execute command with timeout
    var child = std.process.Child.init(cmd_args.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // TODO: Implement timeout handling
    const result = try child.wait();

    if (result != .Exited or result.Exited != 0) {
        return error.CommandFailed;
    }

    // Read output
    var stdout = std.ArrayList(u8).init(allocator);
    defer stdout.deinit();

    if (child.stdout) |stdout_pipe| {
        try stdout_pipe.reader().readAllArrayList(&stdout, 1024 * 1024); // 1MB limit
    }

    return stdout.toOwnedSlice();
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
