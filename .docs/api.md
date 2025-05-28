# MCP Server API Reference

## JSON-RPC Interface
```zig
pub const JsonRpc = struct {
    allocator: std.mem.Allocator,
    registry: *ToolRegistry,
    
    /// Handle incoming JSON-RPC request
    pub fn handleRequest(
        self: *JsonRpc,
        raw_data: []const u8,
        conn_id: u32
    ) ![]const u8 {
        // Parsing and validation logic
        const parsed = try json.parseFromSlice(
            json.Value,
            self.allocator,
            raw_data,
            .{}
        );
        defer parsed.deinit();

        // Execute tool command
        const result = try self.registry.executeCommand(
            parsed.value.method,
            parsed.value.params,
            conn_id
        );

        // Build response
        return try Response.buildSuccessResponse(result, self.allocator);
    }
};
```

## Request Format
```json
{
  "jsonrpc": "2.0",
  "method": "tool_command",
  "params": {
    "arg1": "value1",
    "arg2": 42
  },
  "id": 1
}
```

## Response Format
```json
{
  "jsonrpc": "2.0",
  "result": {/* tool-specific data */},
  "id": 1
}
```

## Error Codes
| Code | Meaning               | Description                          |
|------|-----------------------|--------------------------------------|
| -32601 | Method Not Found    | Requested tool command not registered|
| -32602 | Invalid Params      | Malformed or missing parameters      |
| -32603 | Internal Error      | Server-side processing failure       |

## Calculator Tool

The calculator tool provides basic arithmetic operations through the MCP server. It supports addition, subtraction, multiplication, and division.

### Methods
- **calculate**: Performs the specified arithmetic operation on two numbers.

### Parameters
| Name       | Type   | Description                          |
|------------|--------|--------------------------------------|
| operation  | string | The arithmetic operation to perform ('a' for add, 's' for subtract, 'm' for multiply, 'd' for divide) |
| a          | number | The first operand                    |
| b          | number | The second operand                   |

### Example Request
```json
{
 "jsonrpc": "2.0",
 "method": "calculator",
 "params": {
   "operation": "a",
   "a": 5,
   "b": 3
 },
 "id": 1
}
```

### Example Response
```json
{
 "jsonrpc": "2.0",
 "result": {
   "status": "success",
   "result": 8,
   "operation": "a",
   "a": 5,
   "b": 3
 },
 "id": 1
}
```

### Error Conditions
- **Division by zero**: Returns error code -32000 with message "Division by zero"
- **Invalid operation**: Returns error code -32602 with message "Invalid operation"
- **Invalid numbers**: Returns error code -32602 with message "Invalid number format"

## CLI Tool

The CLI tool allows executing system commands through the MCP server. It supports specifying command, arguments, timeout, and working directory.

### Methods
- **execute**: Runs the specified system command with given arguments.

### Parameters
| Name       | Type   | Description                          |
|------------|--------|--------------------------------------|
| command    | string | The system command to execute        |
| args       | string | Space-separated command arguments    |
| timeout    | number | Maximum execution time in milliseconds (default: 5000) |
| cwd        | string | Working directory for the command    |

### Example Request
```json
{
  "jsonrpc": "2.0",
  "method": "cli",
  "params": {
    "command": "echo",
    "args": "hello",
    "timeout": 1000
  },
  "id": 1
}
```

### Example Success Response
```json
{
  "jsonrpc": "2.0",
  "result": {
    "status": "success",
    "exit_code": 0,
    "command": "echo",
    "args": "hello",
    "stdout": "hello\n",
    "stderr": ""
  },
  "id": 1
}
```

### Example Error Response
```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32000,
    "message": "Command failed",
    "data": {
      "status": "error",
      "exit_code": 127,
      "command": "invalid_cmd",
      "args": "",
      "stdout": "",
      "stderr": "invalid_cmd: command not found"
    }
  },
  "id": 1
}
```

### Error Conditions
- **Missing command**: Returns error code -32602 with message "Missing parameter: command"
- **Command failed**: Returns error code -32000 with message "Command failed"
- **Command timeout**: Returns error code -32001 with message "Command timeout"