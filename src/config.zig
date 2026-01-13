const std = @import("std");
const transport = @import("transport.zig");

/// Server configuration structure
pub const Config = struct {
    // Transport settings
    transport_mode: transport.TransportMode = .stdio,
    tcp_host: []const u8 = "127.0.0.1",
    tcp_port: u16 = 8080,

    // Security settings
    cli_allowed_commands: []const []const u8 = &.{ "echo", "ls" },
    max_command_timeout_ms: u32 = 5000,
    enable_calculator: bool = true,
    enable_cli: bool = true,

    // Performance settings
    max_request_size: usize = 1024 * 1024, // 1MB
    connection_timeout_ms: u32 = 30000,

    // Logging settings
    log_level: std.log.Level = .debug,
    log_requests: bool = true,
    log_responses: bool = true,

    /// Load configuration from environment variables and command line args
    pub fn load(allocator: std.mem.Allocator) !Config {
        var config = Config{};

        // Parse command line arguments
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);

        var i: usize = 1; // Skip program name
        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (std.mem.eql(u8, arg, "--stdio")) {
                config.transport_mode = .stdio;
            } else if (std.mem.eql(u8, arg, "--tcp")) {
                config.transport_mode = .tcp;
            } else if (std.mem.eql(u8, arg, "--port")) {
                if (i + 1 < args.len) {
                    i += 1;
                    config.tcp_port = std.fmt.parseInt(u16, args[i], 10) catch {
                        std.log.warn("Invalid port number: {s}, using default {d}", .{ args[i], config.tcp_port });
                        continue;
                    };
                }
            } else if (std.mem.eql(u8, arg, "--host")) {
                if (i + 1 < args.len) {
                    i += 1;
                    config.tcp_host = args[i];
                }
            } else if (std.mem.eql(u8, arg, "--disable-calculator")) {
                config.enable_calculator = false;
            } else if (std.mem.eql(u8, arg, "--disable-cli")) {
                config.enable_cli = false;
            } else if (std.mem.eql(u8, arg, "--debug")) {
                config.log_level = .debug;
                config.log_requests = true;
                config.log_responses = true;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                printHelp();
                std.process.exit(0);
            }
        }

        // Override with environment variables
        if (std.process.getEnvVarOwned(allocator, "MCP_TRANSPORT")) |transport_env| {
            defer allocator.free(transport_env);
            if (std.mem.eql(u8, transport_env, "stdio")) {
                config.transport_mode = .stdio;
            } else if (std.mem.eql(u8, transport_env, "tcp")) {
                config.transport_mode = .tcp;
            }
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "MCP_PORT")) |port_env| {
            defer allocator.free(port_env);
            config.tcp_port = std.fmt.parseInt(u16, port_env, 10) catch config.tcp_port;
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "MCP_HOST")) |host_env| {
            defer allocator.free(host_env);
            config.tcp_host = host_env;
        } else |_| {}

        return config;
    }

    /// Validate configuration
    pub fn validate(self: *const Config) !void {
        if (self.tcp_port == 0) {
            return error.InvalidPort;
        }

        if (self.max_command_timeout_ms == 0) {
            return error.InvalidTimeout;
        }

        if (self.max_request_size == 0) {
            return error.InvalidRequestSize;
        }
    }

    /// Print configuration summary
    pub fn print(self: *const Config) void {
        std.log.info("MCP Server Configuration:", .{});
        std.log.info("  Transport: {s}", .{@tagName(self.transport_mode)});

        if (self.transport_mode == .tcp) {
            std.log.info("  TCP Address: {s}:{d}", .{ self.tcp_host, self.tcp_port });
        }

        std.log.info("  Calculator enabled: {any}", .{self.enable_calculator});
        std.log.info("  CLI enabled: {any}", .{self.enable_cli});

        if (self.enable_cli) {
            std.log.info("  CLI allowed commands: {d} commands", .{self.cli_allowed_commands.len});
        }

        std.log.info("  Log level: {s}", .{@tagName(self.log_level)});
    }
};

fn printHelp() void {
    const help_text =
        \\MCP Server - Model Context Protocol Server Implementation
        \\
        \\USAGE:
        \\    mcp_server [OPTIONS]
        \\
        \\OPTIONS:
        \\    --stdio                Use stdio transport (default)
        \\    --tcp                  Use TCP transport
        \\    --host <HOST>          TCP host address (default: 127.0.0.1)
        \\    --port <PORT>          TCP port number (default: 8080)
        \\    --disable-calculator   Disable calculator tool
        \\    --disable-cli          Disable CLI tool
        \\    --debug                Enable debug logging
        \\    --help, -h             Show this help message
        \\
        \\ENVIRONMENT VARIABLES:
        \\    MCP_TRANSPORT          Transport mode (stdio|tcp)
        \\    MCP_HOST               TCP host address
        \\    MCP_PORT               TCP port number
        \\
        \\EXAMPLES:
        \\    mcp_server                          # Run with stdio transport
        \\    mcp_server --tcp --port 9000        # Run TCP server on port 9000
        \\    mcp_server --debug                  # Run with debug logging
        \\
    ;
    std.debug.print("{s}", .{help_text});
}
