# mcp.zig

A Zig implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server library.

MCP is an open protocol that enables secure connections between AI assistants and data sources, providing a standardized way for AI models to access context from local and remote resources.

## Features

- **JSON-RPC 2.0** transport layer with proper memory management
- **Content-Length streaming** (LSP/MCP protocol standard)
- **Stdio and TCP** transport support
- **Method dispatcher** with lifecycle hooks (onBefore, onAfter, onError, onFallback)
- **Tool registration** with typed parameter handling and input schemas
- **Resource management** with subscriptions and change notifications
- **Prompt templates** with argument support
- **Progress notifications** for long-running operations
- **Flexible logging** interface
- **Zero dependencies** - pure Zig standard library only
- **Zig 0.15.2+** compatible
- **100% MCP spec compliance** - 103/103 tests passing

## Requirements

- Zig 0.15.2 or later

## Installation

### Option 1: Using `zig fetch` (Recommended)

The easiest way to add `mcp.zig` as a dependency is using the `zig fetch` command, which automatically downloads the package and computes the hash for you:

**Using Git URL (recommended):**

```bash
zig fetch --save git+https://github.com/bkataru/mcp.zig.git
```

**Using tarball URL:**

```bash
zig fetch --save https://github.com/bkataru/mcp.zig/archive/refs/heads/main.tar.gz
```

**To fetch a specific version or tag:**

```bash
# Using git URL with tag reference
zig fetch --save git+https://github.com/bkataru/mcp.zig.git#v0.1.0

# Or using tarball URL for a specific tag
zig fetch --save https://github.com/bkataru/mcp.zig/archive/refs/tags/v0.1.0.tar.gz
```

**To save with a custom dependency name:**

```bash
zig fetch --save=mcp git+https://github.com/bkataru/mcp.zig.git
```

> **Note:** The `git+https://` protocol clones the repository directly, while tarball URLs download a snapshot archive. Git URLs are generally more reliable for version pinning.

### Option 2: Manual Configuration

Alternatively, you can manually add `mcp.zig` as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .mcp = .{
        // Using git URL (recommended)
        .url = "git+https://github.com/bkataru/mcp.zig.git",
        // Or using tarball URL:
        // .url = "https://github.com/bkataru/mcp.zig/archive/refs/heads/main.tar.gz",
        .hash = "...", // Run `zig build` to get the correct hash
    },
},
```

**Note:** On the first build attempt, Zig will display the correct hash value. Copy that hash and update your `build.zig.zon` file accordingly.

### Option 3: Local Path Dependency

For local development or when vendoring:

```zig
.dependencies = .{
    .mcp = .{
        .path = "../mcp.zig",
    },
},
```

### Configuring `build.zig`

After adding the dependency (via any method above), add the following to your `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Fetch the mcp dependency
    const mcp_dep = b.dependency("mcp", .{
        .target = target,
        .optimize = optimize,
    });

    // Get the module from the dependency
    const mcp_mod = mcp_dep.module("mcp");

    // Create your executable
    const exe = b.addExecutable(.{
        .name = "my_mcp_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add the mcp import to your executable
    exe.root_module.addImport("mcp", mcp_mod);

    b.installArtifact(exe);
}
```

### Building from Source

```bash
# Clone the repository
git clone https://github.com/bkataru/mcp.zig.git
cd mcp.zig

# Build the library and server
zig build

# Run tests
zig build test

# Build release version
zig build -Doptimize=ReleaseFast
```

## Quick Start

### Basic MCP Server

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create MCP server
    var server = try mcp.MCPServer.init(allocator);
    defer server.deinit();

    // Register a tool
    try server.registerTool(.{
        .name = "greet",
        .description = "Greets a user by name",
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": {
        \\      "type": "string",
        \\      "description": "Name to greet"
        \\    }
        \\  },
        \\  "required": ["name"]
        \\}
        ,
        .handler = greetHandler,
    });

    // Run the server with stdio transport (Zig 0.15 API)
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    // Create buffered readers/writers
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var reader = stdin.reader(&read_buf);
    var writer = stdout.writer(&write_buf);

    while (true) {
        const message = mcp.readContentLengthFrame(allocator, &reader.interface) catch {
            break;
        };
        defer allocator.free(message);

        if (message.len == 0) continue;

        const response = try server.handleRequest(message);
        defer allocator.free(response);

        if (response.len > 0) {
            try mcp.writeContentLengthFrame(&writer.interface, response);
            try writer.interface.flush();
        }
    }
}

fn greetHandler(_: std.mem.Allocator, params: std.json.Value) !std.json.Value {
    const name = params.object.get("name").?.string;
    return std.json.Value{ .string = std.fmt.allocPrint(std.heap.page_allocator, "Hello, {s}!", .{name}) catch "Hello!" };
}
```

### Using the Method Registry (Advanced)

For more control over request handling, use the registry pattern:

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
    registry.setOnBefore(null, logRequest);
    registry.setOnError(null, logError);

    // Get dispatcher
    const dispatcher = registry.asDispatcher();
}

fn logRequest(ctx: *const mcp.DispatchContext) !void {
    std.debug.print("Handling: {s}\n", .{ctx.request.method});
}

fn logError(ctx: *const mcp.DispatchContext, err: anyerror) mcp.DispatchResult {
    std.debug.print("Error handling {s}: {any}\n", .{ctx.request.method, err});
    return mcp.DispatchResult.withError(-32603, "Internal error");
}

fn handleInitialize(ctx: *const mcp.DispatchContext, _: ?std.json.Value) !mcp.DispatchResult {
    const result = mcp.InitializeResult{
        .protocolVersion = mcp.PROTOCOL_VERSION,
        .capabilities = .{ .tools = .{} },
        .serverInfo = .{ .name = "my-server", .version = "1.0.0" },
    };
    return mcp.DispatchResult.withResult("{}"); // Serialize result to JSON
}
```

## Examples

The project includes several examples demonstrating different features:

| Example | Description |
|---------|-------------|
| `examples/hello_mcp.zig` | Basic server with echo, hello, and get_time tools |
| `examples/calculator_example.zig` | Calculator with add, subtract, multiply, divide, power, sqrt |
| `examples/file_server.zig` | Resource server with file-based resources and subscriptions |
| `examples/prompts_example.zig` | Prompt template server with argument support |
| `examples/comprehensive_example.zig` | Full-featured server demonstrating all capabilities |

Run any example with:

```bash
zig run examples/hello_mcp.zig
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
│   ├── progress.zig   # Progress notification support
│   ├── logger.zig     # Logging interface
│   │
│   │   # Server Implementation
│   ├── mcp.zig        # Core MCP server
│   ├── transport.zig  # Stdio/TCP transport abstraction
│   ├── network.zig    # Network connection handling
│   ├── errors.zig     # Error types and handling
│   ├── config.zig     # Server configuration
│   ├── memory.zig     # Memory management utilities
│   ├── json_utils.zig # JSON utility functions
│   │
│   ├── primitives/    # MCP primitives
│   │   ├── tool.zig       # Tool registration and execution
│   │   ├── resource.zig   # Resource handling with subscriptions
│   │   └── prompt.zig     # Prompt templates
│   │
│   └── tools/         # Built-in tools
│       ├── calculator.zig
│       └── cli.zig
│
├── examples/          # Example MCP servers
└── SPEC_COMPLIANCE.md # MCP specification compliance report
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
const text = mcp.types.textContent("Hello, world!");

// Initialize result
const result = mcp.InitializeResult{
    .protocolVersion = mcp.PROTOCOL_VERSION,
    .capabilities = .{ .tools = .{} },
    .serverInfo = .{ .name = "my-server", .version = "1.0.0" },
};
```

### Method Registry (`mcp.dispatcher`)

Interface-based method routing with lifecycle hooks:

```zig
var registry = mcp.MethodRegistry.init(allocator);
defer registry.deinit();

// Register method handlers
try registry.add("initialize", handleInit);
try registry.add("tools/list", handleToolsList);
try registry.add("tools/call", handleToolsCall);

// Set lifecycle hooks
registry.setOnBefore(null, logRequest);
registry.setOnAfter(null, logResponse);
registry.setOnError(null, logError);
registry.setOnFallback(null, handleUnknown);

// Dispatch request
const dispatcher = registry.asDispatcher();
const result = try dispatcher.dispatch(&context);
```

### Streaming (`mcp.streaming`)

Content-Length message framing (standard for MCP/LSP protocols):

```zig
// Create buffered reader/writer with the new Zig 0.15 Io API
var read_buf: [8192]u8 = undefined;
var write_buf: [8192]u8 = undefined;
var reader = file.reader(&read_buf);
var writer = file.writer(&write_buf);

// Read a Content-Length framed message
const message = try mcp.readContentLengthFrame(allocator, &reader.interface);
defer allocator.free(message);

// Write a Content-Length framed message
try mcp.writeContentLengthFrame(&writer.interface, response);
try writer.interface.flush();

// Or use delimiter-based framing (e.g., newline)
const line = try mcp.readDelimiterFrame(allocator, &reader.interface, '\n');
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

const error_response = try mcp.buildErrorResponse(allocator, id, .methodNotFound, "Unknown method");
defer allocator.free(error_response);
```

### Resources with Subscriptions (`mcp.primitives.resource`)

Manage resources with dynamic subscriptions:

```zig
// Initialize resource registry with subscription support
var resources = mcp.primitives.ResourceRegistry.init(allocator);
defer resources.deinit();

resources.supports_subscriptions = true;

// Register a resource
try resources.register(.{
    .uri = "file:///config.json",
    .name = "Configuration",
    .description = "Application configuration",
    .mimeType = "application/json",
    .handler = configHandler,
});

// Subscribe to updates
const update_callback = struct {
    fn onUpdate(_: std.mem.Allocator, uri: []const u8) !void {
        std.debug.print("Resource updated: {s}\n", .{uri});
    }
}.onUpdate;

try resources.subscribe("file:///config.json", update_callback);

// Later, notify subscribers of changes
try resources.notifyUpdate("file:///config.json");

// Unsubscribe when done
try resources.unsubscribe("file:///config.json");
```

### Prompts (`mcp.primitives.prompt`)

Register and execute prompt templates:

```zig
var prompts = mcp.primitives.PromptRegistry.init(allocator);
defer prompts.deinit();

try prompts.register(.{
    .name = "summarize",
    .description = "Create a summary prompt",
    .arguments = &.{
        .{ .name = "length", .description = "Summary length (brief/detailed)", .required = false },
    },
    .handler = summarizeHandler,
});

const result = try prompts.execute("summarize", .{ .object = .{ .length = .{ .string = "brief" } } });
```

### Progress Notifications (`mcp.progress`)

Track long-running operations:

```zig
var builder = mcp.progress.ProgressBuilder.init(allocator);
const notification = try builder.createProgress(
    .{ .string = "task-123" },
    0.5,
    "Halfway done",
    60.0,
);

// Use with a buffered writer (Zig 0.15 API)
var write_buf: [8192]u8 = undefined;
var file_writer = file.writer(&write_buf);

var tracker = mcp.progress.ProgressTracker.init(allocator, .{ .integer = 1 });
try tracker.update(0.25, "25% complete", &file_writer.interface);
try tracker.complete(&file_writer.interface);
try file_writer.interface.flush();
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

### Transport

Abstraction for stdio and TCP transports:

```zig
// Stdio transport (using std.fs.File.stdin/stdout)
const stdin = std.fs.File.stdin();
const stdout = std.fs.File.stdout();
const transport = mcp.Transport.initFromFiles(stdin, stdout);

// TCP transport (using std.net.Stream)
const transport = mcp.Transport.initFromStream(stream);
```

## Building and Testing

```bash
# Build the library and server
zig build

# Run unit tests
zig build test

# Run the MCP server (stdio mode)
zig build run

# Run the MCP server (TCP mode)
zig build run -- --tcp --port 8080

# Build release version
zig build -Doptimize=ReleaseFast

# Check code formatting
zig fmt --check src/
```

### Test Coverage

The project includes comprehensive tests:

- **103 tests passing** across all modules
- Tests for: jsonrpc, dispatcher, types, primitives, streaming, logger, errors, memory, json_utils, progress

### Integration Testing

The project includes a pure Zig test client for integration testing:

```bash
# Test stdio transport (spawns server automatically)
zig build test-client -- --stdio

# Test TCP transport (requires server to be running)
# In terminal 1:
zig build run -- --tcp
# In terminal 2:
zig build test-client -- --tcp

# Test with custom host/port
zig build test-client -- --tcp --host 127.0.0.1 --port 8080

# Show help
zig build test-client -- --help
```

### Continuous Integration

This project uses GitHub Actions for CI/CD:

- **Multi-platform**: Tests on Ubuntu, Windows, and macOS
- **Zig 0.15.2**: Uses the latest stable Zig release
- **Build & Test**: Runs `zig build` and `zig build test`
- **Format Check**: Verifies code formatting with `zig fmt`

See `.github/workflows/ci.yml` for the full configuration.

## Specification Compliance

The implementation follows the MCP specification (2025-11-25) with 100% compliance on server-side features:

- Base Protocol: 100% (JSON-RPC 2.0, requests, responses, notifications)
- Lifecycle: 100% (initialize, capability negotiation, shutdown)
- Tools: 100% (registration, listing, execution)
- Resources: 100% (list, read, subscriptions)
- Prompts: 100% (registration, listing, execution with arguments)
- Utilities: 100% (logging, progress notifications)

See [SPEC_COMPLIANCE.md](SPEC_COMPLIANCE.md) for detailed coverage report.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Related Projects

- [MCP Specification](https://modelcontextprotocol.io/specification/2025-11-25.md)
- [MCP SDK (TypeScript)](https://github.com/modelcontextprotocol/typescript-sdk)
- [MCP SDK (Python)](https://github.com/modelcontextprotocol/python-sdk)
- [zigjr](https://github.com/williamw520/zigjr) - JSON-RPC library for Zig (architecture reference)
