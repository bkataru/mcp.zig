# Working MCP stdio test script for Windows
# This script demonstrates working approaches for Windows stdio communication

Write-Host "=== Working MCP Server stdio Tests ===" -ForegroundColor Cyan

$mcpPath = "c:\Development\mcp.zig\mcp_server\zig-out\bin\mcp_server.exe"
$testJson = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'

Write-Host "`n=== Test 1: Using temporary file (WORKING) ===" -ForegroundColor Green
$tempFile = [System.IO.Path]::GetTempFileName()
try {
    # Write JSON to temp file
    $testJson | Out-File -FilePath $tempFile -Encoding UTF8 -NoNewline
    
    # Use Get-Content to pipe file contents to server
    Write-Host "Sending: $testJson" -ForegroundColor Yellow
    Get-Content $tempFile | & $mcpPath --stdio
    
    Write-Host "File-based approach completed" -ForegroundColor Green
} finally {
    if (Test-Path $tempFile) { Remove-Item $tempFile }
}

Write-Host "`n=== Test 2: Using here-string with cmd (WORKING) ===" -ForegroundColor Green
$cmd = @"
echo $testJson | "$mcpPath" --stdio
"@

Write-Host "Sending: $testJson" -ForegroundColor Yellow
cmd /c $cmd

Write-Host "`n=== Test 3: Using PowerShell Job (WORKING) ===" -ForegroundColor Green
try {
    # Start server as background job
    $job = Start-Job -ScriptBlock {
        param($serverPath, $jsonData)
        $jsonData | & $serverPath --stdio
    } -ArgumentList $mcpPath, $testJson
    
    Write-Host "Sending: $testJson" -ForegroundColor Yellow
    
    # Wait for job completion with timeout
    $result = Wait-Job $job -Timeout 10
    if ($result) {
        Receive-Job $job
        Write-Host "PowerShell Job approach completed" -ForegroundColor Green
    } else {
        Write-Host "Job timed out" -ForegroundColor Red
    }
} finally {
    Remove-Job $job -Force -ErrorAction SilentlyContinue
}

Write-Host "`n=== Test 4: Interactive mode (WORKING) ===" -ForegroundColor Green
Write-Host "Starting server in interactive mode - type the JSON manually:"
Write-Host "Paste this: $testJson" -ForegroundColor Yellow
Write-Host "Then press Enter and Ctrl+C to exit" -ForegroundColor Cyan
& $mcpPath --stdio

Write-Host "`nAll working tests completed!" -ForegroundColor Green
