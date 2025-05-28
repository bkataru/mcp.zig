# MCP Server Deployment Guide

## Build Requirements
- Zig 0.11.0+
- POSIX-compatible system (Linux/macOS)
- Network access on port 8080

## Build Commands
```bash
# Debug build with assertions
zig build -Doptimize=Debug

# Release build
zig build -Doptimize=ReleaseSafe

# Run server
zig build run -Doptimize=ReleaseSafe
```

## Configuration Options
```zig
// In src/main.zig
const settings = struct {
    pub const max_connections = 100;
    pub const request_timeout = 5000; // milliseconds
    pub const enable_stdio = true;
};
```

## Systemd Service Setup
```ini
[Unit]
Description=MCP Server
After=network.target

[Service]
Type=simple
User=mcp
WorkingDirectory=/opt/mcp
ExecStart=/opt/mcp/zig-out/bin/mcp_server
Restart=always

[Install]
WantedBy=multi-user.target
```

## Monitoring
```bash
# Check active connections
ss -tunlp | grep 8080

# View server logs
journalctl -u mcp.service -f

# Memory usage
pmap -x $(pgrep mcp_server) | tail -n 1
```

## Security Considerations
1. Firewall setup:
```bash
ufw allow 8080/tcp
ufw enable
```

2. TLS Configuration (recommended):
```zig
// In network.zig
const tls_config = net.StreamServer.Options{
    .cert_chain = @embedFile("certs/server.crt"),
    .private_key = @embedFile("certs/server.key"),
};