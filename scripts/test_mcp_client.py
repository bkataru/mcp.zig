#!/usr/bin/env python3
"""
Simple MCP client test for the Zig MCP server.
This will test the server's ability to handle MCP protocol messages.
"""
import json
import subprocess
import sys
import time


def test_mcp_server():
    # Initialize request - standard MCP protocol
    init_request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {
                "tools": {}
            },
            "clientInfo": {
                "name": "mcp-test-client",
                "version": "1.0.0"
            }
        }
    }
    
    # List tools request
    list_tools_request = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/list",
        "params": {}
    }
    
    # Calculator tool call request
    calc_request = {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {
            "name": "calculator",
            "arguments": {
                "expression": "2 + 3 * 4"
            }
        }
    }
    
    print("Starting MCP server test...")
    
    try:
        # Start the server process
        server_process = subprocess.Popen(
            ["main.exe", "--stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1
        )
        
        print("Server started, sending initialize request...")
        
        # Send initialize request
        init_json = json.dumps(init_request) + "\n"
        server_process.stdin.write(init_json)
        server_process.stdin.flush()
        
        # Read response
        response_line = server_process.stdout.readline()
        if response_line:
            print(f"Initialize response: {response_line.strip()}")
        
        # Send list tools request  
        list_json = json.dumps(list_tools_request) + "\n"
        server_process.stdin.write(list_json)
        server_process.stdin.flush()
        
        # Read response
        response_line = server_process.stdout.readline()
        if response_line:
            print(f"List tools response: {response_line.strip()}")
        
        # Send calculator request
        calc_json = json.dumps(calc_request) + "\n"
        server_process.stdin.write(calc_json)
        server_process.stdin.flush()
        
        # Read response
        response_line = server_process.stdout.readline()
        if response_line:
            print(f"Calculator response: {response_line.strip()}")
        
        # Close stdin to signal end of communication
        server_process.stdin.close()
        
        # Wait for server to finish
        server_process.wait(timeout=5)
        
    except subprocess.TimeoutExpired:
        print("Server did not exit within timeout, terminating...")
        server_process.terminate()
        server_process.wait()
    except Exception as e:
        print(f"Error during test: {e}")
        if server_process.poll() is None:
            server_process.terminate()
            server_process.wait()
    
    print("Test completed.")


if __name__ == "__main__":
    test_mcp_server()
