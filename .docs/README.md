# MCP Server Documentation

## Overview
Modular Control Protocol (MCP) server implementation in Zig. Provides extensible tooling infrastructure with JSON-RPC interface.

### Key Features
- Network communication layer (TCP/stdio)
- JSON-RPC 2.0 compliant
- Thread-safe connection handling
- Extensible tool system

## Quick Start

### Running the Server
```bash
zig build run -Doptimize=Debug
```

### Example: Using the Calculator Tool
Perform addition (5 + 3):
```bash
curl -X POST http://localhost:8080 -d '{
  "jsonrpc": "2.0",
  "method": "calculator",
  "params": {"operation": "a", "a": 5, "b": 3},
  "id": 1
}'
```

Expected response:
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

### Example: Using the CLI Tool
Execute a simple command:
```bash
curl -X POST http://localhost:8080 -d '{
  "jsonrpc": "2.0",
  "method": "cli",
  "params": {"command": "echo", "args": "hello"},
  "id": 2
}'
```

Expected response:
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
  "id": 2
}
```

## Installation

### Prerequisites
- Zig compiler (0.11.0 or later)
- Git (for cloning repository)

### Build Steps
```bash
git clone https://github.com/yourorg/mcp_server.git
cd mcp_server
zig build -Doptimize=ReleaseSafe
```

The built binary will be available at `zig-out/bin/mcp_server`.

## Configuration

### Environment Variables
```bash
export MCP_PORT=8080       # Server listening port
export MCP_LOG_LEVEL=info  # Log verbosity (debug, info, warn, error)
```

### Command-line Options
```bash
./zig-out/bin/mcp_server \
  --port 8080 \
  --log-level info \
  --max-connections 100
```

## Next Steps
- See [API Reference](api.md) for detailed endpoint documentation
- Review [Deployment Guide](deployment.md) for production setup
- Explore [Architecture Overview](architecture.md) for system design details