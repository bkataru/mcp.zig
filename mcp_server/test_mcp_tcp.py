#!/usr/bin/env python3
"""
TCP MCP client test for the Zig MCP server.
This will test the server's ability to handle MCP protocol messages over TCP.
"""
import json
import socket
import time
import sys


def test_mcp_server_tcp():
    print("Starting TCP MCP server test...")
    
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
    
    try:
        # Connect to the server
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.connect(('127.0.0.1', 8080))
        print("Connected to server")
        
        # Test 1: Initialize
        print("\n=== Test 1: Initialize ===")
        request_json = json.dumps(init_request) + "\n"
        print(f"Sending: {request_json.strip()}")
        sock.send(request_json.encode('utf-8'))
        
        response = sock.recv(4096).decode('utf-8')
        print(f"Received: {response.strip()}")
        
        if response.strip():
            try:
                response_data = json.loads(response.strip())
                if response_data.get("result"):
                    print("✓ Initialize successful")
                else:
                    print("✗ Initialize failed - no result")
            except json.JSONDecodeError:
                print("✗ Initialize failed - invalid JSON response")
        else:
            print("✗ Initialize failed - no response")
        
        # Test 2: List tools
        print("\n=== Test 2: List Tools ===")
        request_json = json.dumps(list_tools_request) + "\n"
        print(f"Sending: {request_json.strip()}")
        sock.send(request_json.encode('utf-8'))
        
        response = sock.recv(4096).decode('utf-8')
        print(f"Received: {response.strip()}")
        
        if response.strip():
            try:
                response_data = json.loads(response.strip())
                if response_data.get("result") and response_data["result"].get("tools"):
                    tools = response_data["result"]["tools"]
                    print(f"✓ Found {len(tools)} tools:")
                    for tool in tools:
                        print(f"  - {tool.get('name')}: {tool.get('description')}")
                else:
                    print("✗ List tools failed - no tools in result")
            except json.JSONDecodeError:
                print("✗ List tools failed - invalid JSON response")
        else:
            print("✗ List tools failed - no response")
        
        # Test 3: Call calculator tool
        print("\n=== Test 3: Call Calculator Tool ===")
        request_json = json.dumps(calc_request) + "\n"
        print(f"Sending: {request_json.strip()}")
        sock.send(request_json.encode('utf-8'))
        
        response = sock.recv(4096).decode('utf-8')
        print(f"Received: {response.strip()}")
        
        if response.strip():
            try:
                response_data = json.loads(response.strip())
                if response_data.get("result"):
                    print("✓ Calculator tool executed successfully")
                    content = response_data["result"].get("content", [])
                    if content:
                        print(f"Result: {content[0].get('text', 'No text content')}")
                else:
                    print("✗ Calculator tool failed - no result")
            except json.JSONDecodeError:
                print("✗ Calculator tool failed - invalid JSON response")
        else:
            print("✗ Calculator tool failed - no response")
        
        print("\n=== TCP Test Complete ===")
        
    except ConnectionRefusedError:
        print("✗ Could not connect to server - make sure it's running on localhost:8080")
        return False
    except Exception as e:
        print(f"✗ Test failed with error: {e}")
        return False
    finally:
        try:
            sock.close()
        except:
            pass
    
    return True


if __name__ == "__main__":
    success = test_mcp_server_tcp()
    sys.exit(0 if success else 1)
