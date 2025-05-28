# Quick Start Implementation Guide

This guide provides step-by-step instructions for implementing Phase 1 of the MCP server refinement plan.

## Phase 1: Foundation Implementation

### Prerequisites

- Zig 0.14.0 installed
- Understanding of the current project structure
- Reference implementations available in `references/` folder

### Step 1: Transport Abstraction Implementation

#### 1.1 Create Transport Interface

Create `mcp_server/src/transport.zig`:

```zig
const std = @import("std");

pub const Transport = struct {
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,
    mutex: std.Thread.Mutex = .{},

    pub fn writeMessage(self: *Transport, message: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.writer.writeAll(message);
        try self.writer.writeByte('\n');
    }

    pub fn readMessage(self: *Transport, allocator: std.mem.Allocator) ![]u8 {
        // Buffer for reading line by line
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        // Read until newline
        while (true) {
            const byte = try self.reader.readByte();
            if (byte == '\n') break;
            try buffer.append(byte);
        }

        return buffer.toOwnedSlice();
    }
};

pub const StdioTransport = struct {
    transport: Transport,

    pub fn init() StdioTransport {
        return StdioTransport{
            .transport = Transport{
                .reader = std.io.getStdIn().reader().any(),
                .writer = std.io.getStdOut().writer().any(),
            },
        };
    }
};

pub const TcpTransport = struct {
    transport: Transport,
    stream: std.net.Stream,

    pub fn init(stream: std.net.Stream) TcpTransport {
        return TcpTransport{
            .transport = Transport{
                .reader = stream.reader().any(),
                .writer = stream.writer().any(),
            },
            .stream = stream,
        };
    }

    pub fn deinit(self: *TcpTransport) void {
        self.stream.close();
    }
};
```

#### 1.2 Update Main.zig for Transport Selection

Modify `mcp_server/src/main.zig` to support transport selection:

```zig
const std = @import("std");
const Transport = @import("transport.zig");
const JsonRpc = @import("jsonrpc.zig").JsonRpc;
const ToolRegistry = @import("primitives/tool.zig").ToolRegistry;

const TransportMode = enum {
    stdio,
    tcp,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments for transport mode
    const mode = parseTransportMode() catch .stdio;

    // Initialize tool registry and JSON-RPC handler
    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc = JsonRpc.init(allocator, &tool_registry);
    defer rpc.deinit();

    switch (mode) {
        .stdio => try runStdioMode(&rpc, allocator),
        .tcp => try runTcpMode(&rpc, allocator, 8080),
    }
}

fn parseTransportMode() !TransportMode {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--stdio")) return .stdio;
        if (std.mem.eql(u8, arg, "--tcp")) return .tcp;
    }
    return .stdio; // Default to stdio
}

fn runStdioMode(rpc: *JsonRpc, allocator: std.mem.Allocator) !void {
    std.log.info("Starting MCP server in stdio mode", .{});
    
    var stdio_transport = Transport.StdioTransport.init();
    
    while (true) {
        const message = stdio_transport.transport.readMessage(allocator) catch |err| {
            if (err == error.EndOfStream) break;
            std.log.err("Failed to read message: {}", .{err});
            continue;
        };
        defer allocator.free(message);

        const response = rpc.handleRequest(message, allocator) catch |err| {
            std.log.err("Failed to handle request: {}", .{err});
            continue;
        };
        defer allocator.free(response);

        try stdio_transport.transport.writeMessage(response);
    }
}

fn runTcpMode(rpc: *JsonRpc, allocator: std.mem.Allocator, port: u16) !void {
    std.log.info("Starting MCP server on TCP port {}", .{port});
    
    const address = std.net.Address.parseIp("127.0.0.1", port) catch unreachable;
    var listener = try address.listen(.{});
    defer listener.deinit();

    while (true) {
        const connection = try listener.accept();
        std.log.info("Accepted connection from {}", .{connection.address});

        // Handle connection in a separate thread or sequentially for now
        try handleTcpConnection(rpc, connection.stream, allocator);
    }
}

fn handleTcpConnection(rpc: *JsonRpc, stream: std.net.Stream, allocator: std.mem.Allocator) !void {
    var tcp_transport = Transport.TcpTransport.init(stream);
    defer tcp_transport.deinit();

    while (true) {
        const message = tcp_transport.transport.readMessage(allocator) catch |err| {
            if (err == error.EndOfStream) break;
            std.log.err("Failed to read message: {}", .{err});
            break;
        };
        defer allocator.free(message);

        const response = rpc.handleRequest(message, allocator) catch |err| {
            std.log.err("Failed to handle request: {}", .{err});
            continue;
        };
        defer allocator.free(response);

        try tcp_transport.transport.writeMessage(response);
    }
}
```

### Step 2: Enhanced Error Handling

#### 2.1 Create Comprehensive Error Module

Create `mcp_server/src/errors.zig`:

```zig
const std = @import("std");

pub const McpError = error{
    ParseError,
    InvalidRequest,
    MethodNotFound,
    InvalidParams,
    InternalError,
    ServerError,
    UnknownTool,
    SecurityViolation,
    TimeoutError,
    ConnectionError,
};

pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,

    pub const ParseError = JsonRpcError{
        .code = -32700,
        .message = "Parse error",
    };

    pub const InvalidRequest = JsonRpcError{
        .code = -32600,
        .message = "Invalid Request",
    };

    pub const MethodNotFound = JsonRpcError{
        .code = -32601,
        .message = "Method not found",
    };

    pub const InvalidParams = JsonRpcError{
        .code = -32602,
        .message = "Invalid params",
    };

    pub const InternalError = JsonRpcError{
        .code = -32603,
        .message = "Internal error",
    };

    pub const ServerError = JsonRpcError{
        .code = -32000,
        .message = "Server error",
    };

    pub fn fromMcpError(err: McpError) JsonRpcError {
        return switch (err) {
            error.ParseError => ParseError,
            error.InvalidRequest => InvalidRequest,
            error.MethodNotFound => MethodNotFound,
            error.InvalidParams => InvalidParams,
            error.InternalError => InternalError,
            error.UnknownTool => MethodNotFound,
            error.SecurityViolation => ServerError,
            else => InternalError,
        };
    }
};

pub fn createErrorResponse(
    id: ?std.json.Value,
    err: anyerror,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const json_rpc_error = if (err == McpError) 
        JsonRpcError.fromMcpError(@errorCast(err))
    else
        JsonRpcError.InternalError;

    const response = .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = json_rpc_error,
    };

    return try std.json.stringifyAlloc(allocator, response, .{});
}
```

### Step 3: Arena Allocator Integration

#### 3.1 Update JsonRpc Handler

Modify `mcp_server/src/jsonrpc.zig` to use arena allocators:

```zig
pub fn handleRequest(self: *JsonRpc, request_data: []const u8, parent_allocator: std.mem.Allocator) ![]const u8 {
    // Create arena for this request/response cycle
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse request
    const request = std.json.parseFromSlice(
        Request, 
        allocator, 
        request_data, 
        .{ .ignore_unknown_fields = true }
    ) catch |err| {
        std.log.err("Failed to parse JSON request: {}", .{err});
        return errors.createErrorResponse(null, error.ParseError, parent_allocator);
    };
    defer request.deinit();

    // Validate request
    if (!std.mem.eql(u8, request.value.jsonrpc, "2.0")) {
        return errors.createErrorResponse(request.value.id, error.InvalidRequest, parent_allocator);
    }

    // Handle request with arena allocator
    const response = self.dispatchRequest(request.value, allocator) catch |err| {
        return errors.createErrorResponse(request.value.id, err, parent_allocator);
    };

    // Response must be allocated with parent_allocator to outlive arena
    return try std.json.stringifyAlloc(parent_allocator, response, .{});
}
```

### Testing the Implementation

#### Test Stdio Mode

```bash
cd mcp_server
zig build
echo '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}},"id":1}' | ./zig-out/bin/mcp_server --stdio
```

#### Test TCP Mode

Terminal 1:
```bash
./zig-out/bin/mcp_server --tcp
```

Terminal 2:
```bash
echo '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}},"id":1}' | nc localhost 8080
```

### Validation Checklist

- [ ] Transport abstraction implemented
- [ ] Both stdio and TCP modes working
- [ ] Enhanced error handling with proper JSON-RPC codes
- [ ] Arena allocators preventing memory leaks
- [ ] Clean separation between transport and protocol logic
- [ ] Command-line argument parsing for transport selection

### Next Steps

After completing Phase 1:

1. Implement type-safe tool system (Phase 2)
2. Add MCP protocol compliance
3. Enhance calculator and CLI tools
4. Add comprehensive testing

This foundation provides the infrastructure needed for the remaining implementation phases.
