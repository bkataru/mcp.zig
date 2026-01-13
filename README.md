# mcp.zig

A Zig implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server library.

MCP is an open protocol that enables secure connections between AI assistants and data sources, providing a standardized way for AI models to access context from local and remote resources.

## Features

- **JSON-RPC 2.0** transport layer with proper memory management
- **Content-Length streaming** (LSP/MCP protocol standard)
- **Stdio and TCP** transport support
- **Method dispatcher** with lifecycle hooks (onBefore, onAfter, onError)
- **Tool registration** with typed parameter handling
- **Resource and Prompt** primitives (extensible)
- **Flexible logging** interface
- **Zero dependencies** - pure Zig standard library only
- **Zig 0.15.2+** compatible

## Requirements

- Zig 0.15.2 or later

## Installation

Add this package to your `build.zig.zon`:

```zig
.dependencies = .{
    .mcp = .{
        .url = "https://github.com/bkataru/mcp.zig/archive/refs/heads/main.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const mcp = b.dependency("mcp", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("mcp", mcp.module("mcp"));
```

## Quick Start

### Using the Method Dispatcher (Recommended)

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create method registry
    var registry = mcp.MethodRegistry.init(allocator);
    defer registry.deinit();

    // Register handlers
    try registry.add("initialize", handleInitialize);
    try registry.add("tools/list", handleToolsList);
    try registry.add("tools/call", handleToolsCall);

    // Set up lifecycle hooks
    registry.setHooks(.{
        .on_before = logRequest,
        .on_error = logError,
    });

    // Run Content-Length streaming server
    const stdin = std.fs.cwd().openFile("/dev/stdin", .{});
    const stdout = std.fs.cwd().openFile("/dev/stdout", .{ .mode = .write_only });
    
    while (true) {
        const message = try mcp.readContentLengthFrame(allocator, stdin.reader());
        defer allocator.free(message);
        
        var parsed = try mcp.parseRequest(allocator, message);
        defer parsed.deinit();
        
        var ctx = mcp.DispatchContext.init(allocator, &parsed.request);
        const result = try registry.asDispatcher().dispatch(&ctx);
        
        const response = try mcp.buildResponse(allocator, ctx.request.id, result.value);
        defer allocator.free(response);
        
        try mcp.writeContentLengthFrame(stdout.writer(), response);
    }
}

fn handleInitialize(ctx: *mcp.DispatchContext, _: ?std.json.Value) !mcp.DispatchResult {
    return mcp.DispatchResult.jsonValue(mcp.InitializeResult{
        .protocolVersion = mcp.PROTOCOL_VERSION,
        .capabilities = .{ .tools = .{ .listChanged = true } },
        .serverInfo = .{ .name = "my-server", .version = "1.0.0" },
    });
}
```

### Legacy MCPServer Usage

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create MCP server
    var server = mcp.MCPServer.init(allocator, .{
        .name = "my-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    // Register a tool
    try server.registerTool(.{
        .name = "greet",
        .description = "Greets a user by name",
        .inputSchema = .{
            .type = "object",
            .properties = .{
                .name = .{ .type = "string", .description = "Name to greet" },
            },
            .required = &[_][]const u8{"name"},
        },
    }, greetHandler);

    // Run the server
    try server.run();
}

fn greetHandler(allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
    const name = params.object.get("name").?.string;
    const greeting = try std.fmt.allocPrint(allocator, "Hello, {s}!", .{name});
    return std.json.Value{ .string = greeting };
}
```

### Building

```bash
# Build the library
zig build

# Run tests
zig build test

# Build release version
zig build -Doptimize=ReleaseFast
```

## Architecture

```
mcp.zig/
├── build.zig          # Build configuration
├── build.zig.zon      # Package manifest
├── src/
│   ├── lib.zig        # Library entry point
│   │
│   │   # Core Protocol
│   ├── types.zig      # MCP protocol type definitions
│   ├── jsonrpc.zig    # JSON-RPC 2.0 protocol handler
│   ├── streaming.zig  # Content-Length message framing
│   ├── dispatcher.zig # Method routing with lifecycle hooks
│   ├── logger.zig     # Logging interface
│   │
│   │   # Server Implementation
│   ├── mcp.zig        # Core MCP server (legacy)
│   ├── transport.zig  # Stdio/TCP transport abstraction
│   ├── network.zig    # Network connection handling
│   ├── errors.zig     # Error types and handling
│   ├── config.zig     # Server configuration
│   ├── memory.zig     # Memory management utilities
│   ├── test_client.zig # Pure Zig integration test client
│   │
│   ├── primitives/    # MCP primitives
│   │   ├── tool.zig       # Tool registration and execution
│   │   ├── resource.zig   # Resource handling
│   │   └── prompt.zig     # Prompt templates
│   └── tools/         # Built-in tools
│       ├── calculator.zig
│       └── cli.zig
```

## API Reference

### Protocol Types (`mcp.types`)

MCP protocol types as Zig structs for automatic JSON serialization:

```zig
// Tool definition
const tool = mcp.Tool{
    .name = "calculator",
    .description = "Performs math operations",
    .inputSchema = schema,
};

// Content types
const text = mcp.textContent("Hello, world!");

// Initialize response
const result = mcp.InitializeResult{
    .protocolVersion = mcp.PROTOCOL_VERSION,
    .capabilities = .{ .tools = .{ .listChanged = true } },
    .serverInfo = .{ .name = "my-server", .version = "1.0.0" },
};
```

### Method Dispatcher (`mcp.dispatcher`)

Interface-based method routing with lifecycle hooks:

```zig
var registry = mcp.MethodRegistry.init(allocator);
defer registry.deinit();

// Register method handlers
try registry.add("initialize", handleInit);
try registry.add("tools/list", handleToolsList);
try registry.add("tools/call", handleToolsCall);

// Set lifecycle hooks
registry.setHooks(.{
    .on_before = fn(ctx) { /* called before dispatch */ },
    .on_after = fn(ctx, result) { /* called after success */ },
    .on_error = fn(ctx, err) { /* called on error */ },
    .on_fallback = fn(ctx) { /* called for unknown methods */ },
});

// Dispatch request
const dispatcher = registry.asDispatcher();
const result = try dispatcher.dispatch(&context);
```

### Streaming (`mcp.streaming`)

Content-Length message framing (standard for MCP/LSP protocols):

```zig
// Read a Content-Length framed message
const message = try mcp.readContentLengthFrame(allocator, reader);
defer allocator.free(message);

// Write a Content-Length framed message
try mcp.writeContentLengthFrame(writer, response);

// Or use delimiter-based framing (e.g., newline)
const line = try mcp.readDelimiterFrame(allocator, reader, '\n');
```

### JSON-RPC (`mcp.jsonrpc`)

Low-level JSON-RPC 2.0 implementation:

```zig
// Parse a request (keeps JSON memory alive)
var parsed = try mcp.parseRequest(allocator, json_string);
defer parsed.deinit();

const method = parsed.request.method;
const params = parsed.request.params;

// Build responses
const response = try mcp.buildResponse(allocator, id, result);
defer allocator.free(response);

const error_response = try mcp.buildErrorResponse(allocator, id, .MethodNotFound, "Unknown method");
defer allocator.free(error_response);
```

### Logging (`mcp.logger`)

Flexible logging interface:

```zig
// No-op logger (default)
var nop = mcp.NopLogger{};
const logger = nop.asLogger();

// Stderr logger (uses std.log)
var stderr = mcp.StderrLogger{ .prefix = "MCP" };
const logger = stderr.asLogger();

// File logger
var file_logger = try mcp.FileLogger.init(allocator, "server.log");
defer file_logger.deinit();
const logger = file_logger.asLogger();

// Use the logger
logger.start("Server starting");
logger.log("transport", "read", "Received message");
logger.stop("Server stopped");
```

### Transport (Legacy)

Abstraction for stdio and TCP transports:

```zig
// Stdio transport
const transport = mcp.Transport.initFromFiles(stdin_file, stdout_file);

// TCP transport  
const transport = mcp.Transport.initFromStream(stream);
```

## Testing

Run the unit test suite:

```bash
zig build test
```

### Integration Testing

The project includes a pure Zig test client for integration testing:

```bash
# Build the test client
zig build

# Test stdio transport (spawns server automatically)
zig build test-client -- --stdio

# Test TCP transport (requires server to be running)
# In terminal 1:
zig build run -- --tcp
# In terminal 2:
zig build test-client -- --tcp

# Show help
zig build test-client -- --help
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Related Projects

- [MCP Specification](https://spec.modelcontextprotocol.io/)
- [MCP SDK (TypeScript)](https://github.com/modelcontextprotocol/typescript-sdk)
- [MCP SDK (Python)](https://github.com/modelcontextprotocol/python-sdk)
- [zigjr](https://github.com/williamw520/zigjr) - JSON-RPC library for Zig (architecture reference)
