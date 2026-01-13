# mcp.zig

A Zig implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server library.

MCP is an open protocol that enables secure connections between AI assistants and data sources, providing a standardized way for AI models to access context from local and remote resources.

## Features

- **JSON-RPC 2.0** transport layer with proper memory management
- **Stdio and TCP** transport support
- **Tool registration** with typed parameter handling
- **Resource and Prompt** primitives (extensible)
- **Zero dependencies** - pure Zig standard library only
- **Zig 0.15.2+** compatible

## Requirements

- Zig 0.15.2 or later

## Installation

Add this package to your `build.zig.zon`:

```zig
.dependencies = .{
    .mcp = .{
        .url = "https://github.com/yourusername/mcp.zig/archive/refs/heads/main.tar.gz",
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

### As a Library

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

### Building the Executable

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
├── build.zig        # Build configuration
├── build.zig.zon    # Package manifest
├── src/
│   ├── lib.zig      # Library entry point
│   ├── mcp.zig      # Core MCP server implementation
│   ├── jsonrpc.zig  # JSON-RPC 2.0 protocol handler
│   ├── transport.zig # Stdio/TCP transport abstraction
│   ├── network.zig  # Network connection handling
│   ├── errors.zig   # Error types and handling
│   ├── config.zig   # Server configuration
│   ├── memory.zig   # Memory management utilities
│   ├── primitives/  # MCP primitives
│   │   ├── tool.zig     # Tool registration and execution
│   │   ├── resource.zig # Resource handling
│   │   └── prompt.zig   # Prompt templates
│   └── tools/       # Built-in tools
│       ├── calculator.zig
│       └── cli.zig
└── scripts/         # Integration test scripts
```

## API Reference

### MCPServer

The main server type that handles MCP protocol communication.

```zig
const server = mcp.MCPServer.init(allocator, .{
    .name = "server-name",
    .version = "1.0.0",
});
```

### Transport

Abstraction for stdio and TCP transports:

```zig
// Stdio transport
const transport = mcp.Transport.initFromFiles(
    std.io.getStdIn().handle,
    std.io.getStdOut().handle,
);

// TCP transport  
const transport = try mcp.Transport.initFromStream(stream);
```

### JSON-RPC

Low-level JSON-RPC 2.0 implementation:

```zig
// Parse a request
var parsed = try mcp.jsonrpc.parseRequest(allocator, json_string);
defer parsed.deinit();

// Build a response
const response = try mcp.jsonrpc.buildResponse(allocator, id, result);
defer allocator.free(response);
```

## Testing

Run the test suite:

```bash
zig build test
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Related Projects

- [MCP Specification](https://spec.modelcontextprotocol.io/)
- [MCP SDK (TypeScript)](https://github.com/modelcontextprotocol/typescript-sdk)
- [MCP SDK (Python)](https://github.com/modelcontextprotocol/python-sdk)
