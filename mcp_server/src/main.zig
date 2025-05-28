const std = @import("std");
const builtin = @import("builtin");
const Calculator = @import("./tools/calculator.zig").Calculator;
const mcp = @import("mcp.zig");
const Network = @import("network.zig").Network;
const JsonRpc = @import("jsonrpc.zig").JsonRpc;
const ToolRegistry = @import("primitives/tool.zig").ToolRegistry;
const calculator = @import("tools/calculator.zig");
const cli = @import("tools/cli.zig");
const transport = @import("transport.zig");
const errors = @import("errors.zig");
const config = @import("config.zig");
const memory = @import("memory.zig");

/// Main entry point for the MCP server
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    var server_config = config.Config.load(allocator) catch |err| {
        std.log.err("Failed to load configuration: {any}", .{err});
        return;
    };

    try server_config.validate();
    server_config.print();

    // Initialize memory management
    var arena_pool = memory.ArenaPool.init(allocator, 4) catch |err| {
        std.log.err("Failed to initialize arena pool: {any}", .{err});
        return;
    };
    defer arena_pool.deinit();

    var memory_tracker = memory.MemoryTracker.init();

    // Initialize logging
    std.log.info("Starting MCP server...", .{});

    // Initialize tool registry and JSON-RPC handler
    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc = JsonRpc.init(allocator, &tool_registry);
    defer rpc.deinit();

    // Initialize MCP server and register tools
    var server = try mcp.MCPServer.init(allocator);
    defer {
        server.deinit();
        std.log.info("MCP server shutdown complete", .{});
    }

    // Register tools based on configuration
    try registerTools(&server, allocator, &server_config);
    std.log.info("Registered {d} tools", .{server.tools.count()}); // Initialize transport based on configuration
    switch (server_config.transport_mode) {
        .stdio => {
            var stdio_transport = transport.StdioTransport.init();
            defer stdio_transport.deinit();

            std.log.info("Starting stdio transport...", .{});
            try runStdioServer(&stdio_transport, &server, &arena_pool, &memory_tracker, &server_config);
        },
        .tcp => {
            // Initialize network layer for TCP transport
            var network = try Network.init(allocator, &rpc, server_config.tcp_port);
            defer {
                network.deinit();
                std.log.info("Network shutdown complete", .{});
            }
            std.log.info("Starting TCP transport on {s}:{d}...", .{ server_config.tcp_host, server_config.tcp_port });
            try runTcpServer(network, &server, &arena_pool, &memory_tracker, &server_config);
        },
    }
}

/// Run the server with stdio transport
fn runServer(
    server_transport: *transport.Transport,
    server: *mcp.MCPServer,
    arena_pool: *memory.ArenaPool,
    memory_tracker: *memory.MemoryTracker,
    server_config: *const config.Config,
) !void {
    std.log.info("Starting server on {s} transport", .{@tagName(server_config.transport_mode)});

    while (true) {
        // Use scoped arena for each request
        var scoped_arena = memory.ScopedArena.init(arena_pool) catch |err| {
            std.log.err("Failed to acquire arena: {any}", .{err});
            continue;
        };
        defer scoped_arena.deinit();

        memory_tracker.recordAllocation(); // Read request
        const request_data = server_transport.readMessage(scoped_arena.allocator()) catch |err| switch (err) {
            error.EndOfStream => {
                std.log.info("Client disconnected", .{});
                break;
            },
            error.Unexpected => {
                // Handle invalid pipe/stdin (e.g., when echo terminates)
                std.log.info("Input stream closed", .{});
                break;
            },
            error.BrokenPipe => {
                std.log.info("Broken pipe detected", .{});
                break;
            },
            else => {
                std.log.err("Failed to read request: {any}", .{err}); // For stdio mode, any read error likely means the stream is dead
                if (server_config.transport_mode == .stdio) {
                    std.log.info("Stdio transport error, exiting", .{});
                    break;
                }
                continue;
            },
        };

        // Process request and send response
        processRequest(server_transport, request_data, server, scoped_arena.allocator()) catch |err| {
            std.log.err("Failed to process request: {any}", .{err});
        };

        memory_tracker.recordDeallocation();

        // Update memory statistics periodically
        if (memory_tracker.getStats().total_allocations % 100 == 0) {
            memory_tracker.updateStats(arena_pool);
            if (std.log.defaultLogEnabled(.debug)) {
                memory_tracker.printStats();
            }
        }
    }
}

/// Run the server with enhanced stdio transport for Windows pipe handling
fn runStdioServer(
    stdio_transport: *transport.StdioTransport,
    server: *mcp.MCPServer,
    arena_pool: *memory.ArenaPool,
    memory_tracker: *memory.MemoryTracker,
    server_config: *const config.Config,
) !void {
    std.log.info("Starting server on stdio transport with enhanced Windows handling", .{});

    while (true) {
        // Use scoped arena for each request
        var scoped_arena = memory.ScopedArena.init(arena_pool) catch |err| {
            std.log.err("Failed to acquire arena: {any}", .{err});
            continue;
        };
        defer scoped_arena.deinit();

        memory_tracker.recordAllocation(); // Read request

        // Use enhanced stdio reading that handles Windows pipe issues
        const request_data = stdio_transport.readMessageWithFallback(scoped_arena.allocator()) catch |err| switch (err) {
            error.EndOfStream => {
                std.log.info("Input stream closed or pipe disconnected", .{});
                break;
            },
            error.Unexpected => {
                // Handle invalid pipe/stdin (e.g., when echo terminates)
                std.log.info("Input stream closed (Windows pipe issue)", .{});
                break;
            },
            error.BrokenPipe => {
                std.log.info("Broken pipe detected", .{});
                break;
            },
            else => {
                std.log.err("Failed to read request: {any}", .{err});
                std.log.info("Stdio transport error, exiting", .{});
                break;
            },
        };

        // Process request and send response
        processRequest(&stdio_transport.transport, request_data, server, scoped_arena.allocator()) catch |err| {
            std.log.err("Failed to process request: {any}", .{err});
        };

        memory_tracker.recordDeallocation();

        // Optional: Add a small delay to prevent busy waiting in case of errors
        if (server_config.log_level == .debug) {
            std.time.sleep(1 * std.time.ns_per_ms); // 1ms delay for debug builds
        }
    }
}

/// Run the server with TCP transport
fn runTcpServer(
    network: *Network,
    server: *mcp.MCPServer,
    arena_pool: *memory.ArenaPool,
    memory_tracker: *memory.MemoryTracker,
    server_config: *const config.Config,
) !void {
    _ = network; // Network module not used directly in this implementation    // Create the TCP server socket
    const address = std.net.Address.parseIp(server_config.tcp_host, server_config.tcp_port) catch |err| {
        std.log.err("Failed to parse address {s}:{d}: {}", .{ server_config.tcp_host, server_config.tcp_port, err });
        return err;
    };

    var server_sock = address.listen(.{}) catch |err| {
        std.log.err("Failed to listen on {s}:{d}: {}", .{ server_config.tcp_host, server_config.tcp_port, err });
        return err;
    };
    defer server_sock.deinit();

    std.log.info("TCP server listening on {s}:{d}", .{ server_config.tcp_host, server_config.tcp_port });

    // Accept and handle connections
    while (true) {
        const connection = server_sock.accept() catch |err| {
            std.log.err("Failed to accept connection: {}", .{err});
            continue;
        };

        std.log.info("New client connected from {}", .{connection.address});

        // Handle the connection in a separate thread or inline
        handleTcpConnection(connection.stream, server, arena_pool, memory_tracker) catch |err| {
            std.log.err("Failed to handle connection: {}", .{err});
        };

        connection.stream.close();
    }
}

/// Handle a single TCP connection
fn handleTcpConnection(
    stream: std.net.Stream,
    server: *mcp.MCPServer,
    arena_pool: *memory.ArenaPool,
    memory_tracker: *memory.MemoryTracker,
) !void {
    // Create transport for this connection
    var tcp_transport = transport.Transport{
        .reader = stream.reader().any(),
        .writer = stream.writer().any(),
        .mutex = std.Thread.Mutex{},
    };

    // Handle messages from this client
    while (true) {
        var scoped_arena = arena_pool.acquire() catch |err| {
            std.log.err("Failed to acquire arena: {any}", .{err});
            continue;
        };
        defer scoped_arena.deinit();

        memory_tracker.recordAllocation();
        const request_data = tcp_transport.readMessage(scoped_arena.allocator()) catch |err| switch (err) {
            error.EndOfStream => {
                std.log.info("Client disconnected", .{});
                break;
            },
            else => {
                std.log.err("Failed to read request: {any}", .{err});
                break;
            },
        };

        // Process request and send response
        processRequest(
            &tcp_transport,
            request_data,
            server,
            scoped_arena.allocator(),
        ) catch |err| {
            std.log.err("Failed to process request: {any}", .{err});
        };

        memory_tracker.recordDeallocation();
    }
}

/// Process a single request
fn processRequest(
    server_transport: *transport.Transport,
    request_data: []const u8,
    server: *mcp.MCPServer,
    allocator: std.mem.Allocator,
) !void { // Parse JSON request
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, request_data, .{}) catch |err| {
        const error_response = try errors.createErrorResponse(null, err, allocator);
        defer allocator.free(error_response);
        try server_transport.writeMessage(error_response);
        return;
    };
    defer parsed.deinit();

    const request = parsed.value;

    // Validate JSON-RPC structure
    errors.validateJsonRpcRequest(request) catch |err| {
        const error_response = try errors.createErrorResponse(
            request.object.get("id"),
            err,
            allocator,
        );
        defer allocator.free(error_response);
        try server_transport.writeMessage(error_response);
        return;
    };

    // Extract request components
    const method = request.object.get("method").?.string;
    const params = request.object.get("params");
    const id = request.object.get("id");

    // Handle MCP methods
    const response = handleMcpMethod(server, method, params, id, allocator) catch |err| {
        const error_response = try errors.createErrorResponse(id, err, allocator);
        defer allocator.free(error_response);
        try server_transport.writeMessage(error_response);
        return;
    };
    defer allocator.free(response);

    try server_transport.writeMessage(response);
}

/// Handle MCP protocol methods
fn handleMcpMethod(
    server: *mcp.MCPServer,
    method: []const u8,
    params: ?std.json.Value,
    id: ?std.json.Value,
    allocator: std.mem.Allocator,
) ![]const u8 {
    if (std.mem.eql(u8, method, "initialize")) {
        return handleInitialize(params, id, allocator);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        return handleToolsList(server, id, allocator);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        return handleToolsCall(server, params, id, allocator);
    } else {
        return error.MethodNotFound;
    }
}

/// Handle initialize method
fn handleInitialize(params: ?std.json.Value, id: ?std.json.Value, allocator: std.mem.Allocator) ![]const u8 {
    _ = params; // TODO: Validate client capabilities

    var capabilities_map = std.json.ObjectMap.init(allocator);
    try capabilities_map.put("tools", std.json.Value{ .object = std.json.ObjectMap.init(allocator) });

    var server_info_map = std.json.ObjectMap.init(allocator);
    try server_info_map.put("name", std.json.Value{ .string = "mcp-zig-server" });
    try server_info_map.put("version", std.json.Value{ .string = "1.0.0" });

    var result_map = std.json.ObjectMap.init(allocator);
    try result_map.put("protocolVersion", std.json.Value{ .string = "2024-11-05" });
    try result_map.put("capabilities", std.json.Value{ .object = capabilities_map });
    try result_map.put("serverInfo", std.json.Value{ .object = server_info_map });

    var response_map = std.json.ObjectMap.init(allocator);
    try response_map.put("jsonrpc", std.json.Value{ .string = "2.0" });
    try response_map.put("result", std.json.Value{ .object = result_map });

    if (id) |id_val| {
        try response_map.put("id", id_val);
    } else {
        try response_map.put("id", std.json.Value{ .null = {} });
    }

    const response = std.json.Value{ .object = response_map };
    return try std.json.stringifyAlloc(allocator, response, .{});
}

/// Handle tools/list method
fn handleToolsList(server: *mcp.MCPServer, id: ?std.json.Value, allocator: std.mem.Allocator) ![]const u8 {
    var tools_array = std.ArrayList(std.json.Value).init(allocator);
    defer tools_array.deinit();

    var iterator = server.tools.iterator();
    while (iterator.next()) |entry| {
        const tool_instance = entry.value_ptr.*;

        // Create tool info as a JSON object map
        var tool_map = std.json.ObjectMap.init(allocator);
        try tool_map.put("name", std.json.Value{ .string = tool_instance.name });
        try tool_map.put("description", std.json.Value{ .string = tool_instance.description });

        var schema_map = std.json.ObjectMap.init(allocator);
        try schema_map.put("type", std.json.Value{ .string = "object" });

        var properties_map = std.json.ObjectMap.init(allocator);
        var param_iter = tool_instance.parameters.iterator();
        while (param_iter.next()) |param_entry| {
            var param_map = std.json.ObjectMap.init(allocator);
            try param_map.put("type", std.json.Value{ .string = param_entry.value_ptr.* });
            try properties_map.put(param_entry.key_ptr.*, std.json.Value{ .object = param_map });
        }

        try schema_map.put("properties", std.json.Value{ .object = properties_map });
        try tool_map.put("inputSchema", std.json.Value{ .object = schema_map });

        try tools_array.append(std.json.Value{ .object = tool_map });
    }

    var result_map = std.json.ObjectMap.init(allocator);
    try result_map.put("tools", std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, try tools_array.toOwnedSlice()) });

    var response_map = std.json.ObjectMap.init(allocator);
    try response_map.put("jsonrpc", std.json.Value{ .string = "2.0" });
    try response_map.put("result", std.json.Value{ .object = result_map });

    if (id) |id_val| {
        try response_map.put("id", id_val);
    } else {
        try response_map.put("id", std.json.Value{ .null = {} });
    }

    const response = std.json.Value{ .object = response_map };
    return try std.json.stringifyAlloc(allocator, response, .{});
}

/// Handle tools/call method
fn handleToolsCall(
    server: *mcp.MCPServer,
    params: ?std.json.Value,
    id: ?std.json.Value,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const params_obj = params orelse return error.InvalidParams;
    const tool_name = params_obj.object.get("name") orelse return error.InvalidParams;
    const arguments = params_obj.object.get("arguments");

    const tool_instance = server.tools.get(tool_name.string) orelse return error.UnknownTool;

    // Convert arguments to StringHashMap
    var param_map = std.StringHashMap([]const u8).init(allocator);
    defer param_map.deinit();

    if (arguments) |args| {
        if (args.object.count() > 0) {
            var arg_iter = args.object.iterator();
            while (arg_iter.next()) |entry| {
                const value_str = switch (entry.value_ptr.*) {
                    .string => |s| s,
                    .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
                    .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
                    .bool => |b| if (b) "true" else "false",
                    else => "unknown",
                };
                try param_map.put(entry.key_ptr.*, value_str);
            }
        }
    }
    // Execute tool
    const tool_result = tool_instance.handler(allocator, param_map) catch {
        return error.ToolExecutionFailed;
    };
    defer allocator.free(tool_result);

    // Create response
    var content_array = std.json.Array.init(allocator);
    var content_map = std.json.ObjectMap.init(allocator);
    try content_map.put("type", std.json.Value{ .string = "text" });
    try content_map.put("text", std.json.Value{ .string = tool_result });
    try content_array.append(std.json.Value{ .object = content_map });

    var result_map = std.json.ObjectMap.init(allocator);
    try result_map.put("content", std.json.Value{ .array = content_array });

    var response_map = std.json.ObjectMap.init(allocator);
    try response_map.put("jsonrpc", std.json.Value{ .string = "2.0" });
    try response_map.put("result", std.json.Value{ .object = result_map });

    if (id) |id_val| {
        try response_map.put("id", id_val);
    } else {
        try response_map.put("id", std.json.Value{ .null = {} });
    }

    const response = std.json.Value{ .object = response_map };
    return try std.json.stringifyAlloc(allocator, response, .{});
}

/// Register tools with the server based on configuration
fn registerTools(server: *mcp.MCPServer, allocator: std.mem.Allocator, server_config: *const config.Config) !void {
    if (server_config.enable_calculator) {
        // Register calculator tool
        const calc_tool = try calculator.init(allocator);
        try server.tools.put(calc_tool.name, calc_tool);
        std.log.info("Registered calculator tool", .{});
    }

    if (server_config.enable_cli) {
        // Register CLI tool
        const cli_tool = try cli.init(allocator);
        try server.tools.put(cli_tool.name, cli_tool);
        std.log.info("Registered CLI tool", .{});
    }
}
