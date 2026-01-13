#!/usr/bin/env powershell
# Test script for stdio transport that keeps the pipe open

$json = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'

# Method 1: Use here-string to keep pipe open longer
@"
$json
"@ | .\zig-out\bin\mcp_server.exe --stdio

Write-Host "=== Method 1 completed ==="

# Method 2: Write to temp file and pipe from that
$tempFile = [System.IO.Path]::GetTempFileName()
$json | Out-File -FilePath $tempFile -Encoding ASCII
Get-Content $tempFile | .\zig-out\bin\mcp_server.exe --stdio
Remove-Item $tempFile

Write-Host "=== Method 2 completed ==="
