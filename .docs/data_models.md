# MCP Server Data Models

## Core Structures
```zig
// From primitives/tool.zig
pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(*ToolDescriptor),

    pub const ToolDescriptor = struct {
        name: []const u8,
        version: []const u8,
        execute: *const fn (
            self: *Tool,
            params: json.Value,
            conn_id: u32
        ) anyerror!json.Value,
        dependencies: []const Dependency,
    };

    pub const Dependency = struct {
        name: []const u8,
        min_version: []const u8,
    };
};
```

## Message Formats
### Request Envelope
```zig
pub const Request = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: json.Value,
    id: u32,
};
```

### Response Envelope
```zig
pub const Response = struct {
    jsonrpc: []const u8 = "2.0",
    result: ?json.Value = null,
    error: ?Error = null,
    id: u32,

    pub const Error = struct {
        code: i32,
        message: []const u8,
        data: ?json.Value = null,
    };
};
```

## Field Specifications
### ToolDescriptor Fields
| Field         | Type     | Description                          |
|---------------|----------|--------------------------------------|
| name          | string   | Unique tool identifier               |
| version       | string   | Semantic version (major.minor.patch) |
| execute       | function | Command execution handler            |
| dependencies  | array    | Required dependencies list           |

### Dependency Structure
| Field        | Type   | Description                          |
|-------------|--------|--------------------------------------|
| name        | string | Dependency package name             |
| min_version | string | Minimum required version            |