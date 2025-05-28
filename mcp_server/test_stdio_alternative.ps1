# Test different approaches to keep stdio pipe open for Windows MCP server

Write-Host "Testing Windows stdio pipe approaches..."

# Method 1: Using here-string (PowerShell specific)
Write-Host "`n=== Test 1: PowerShell here-string ==="
$json = @"
{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
"@

$json | .\zig-out\bin\mcp_server.exe --stdio

Write-Host "`n=== Test 2: Temporary file approach ==="
# Method 2: Write to temp file and redirect
$tempFile = [System.IO.Path]::GetTempFileName()
'{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | Out-File -FilePath $tempFile -Encoding ASCII -NoNewline
Get-Content $tempFile | .\zig-out\bin\mcp_server.exe --stdio
Remove-Item $tempFile

Write-Host "`n=== Test 3: Direct string with delay ==="
# Method 3: Use Start-Process to pipe with delay
$jsonString = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
$process = Start-Process -FilePath ".\zig-out\bin\mcp_server.exe" -ArgumentList "--stdio" -RedirectStandardInput -PassThru -NoNewWindow
Start-Sleep -Milliseconds 100  # Give process time to start
$jsonString | Out-String | ForEach-Object { $process.StandardInput.Write($_) }
$process.StandardInput.Close()
$process.WaitForExit()

Write-Host "`n=== Test 4: Using cmd echo (different pipe behavior) ==="
# Method 4: Use cmd echo instead of PowerShell echo
cmd /c 'echo {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}} | .\zig-out\bin\mcp_server.exe --stdio'

Write-Host "`nAll tests completed."
