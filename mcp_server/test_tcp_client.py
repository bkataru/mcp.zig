#!/usr/bin/env python3
"""
TCP MCP client test for the Zig MCP server.
Tests the server's MCP protocol implementation over TCP.
"""
import json
import socket
import sys
import time


def send_json_request(sock, request):
    """Send a JSON-RPC request over the socket."""
    message = json.dumps(request) + '\n'
    print(f"Sending: {message.strip()}")
    sock.send(message.encode('utf-8'))


def read_json_response(sock):
    """Read a JSON-RPC response from the socket."""
    buffer = ""
    while True:
        data = sock.recv(1024).decode('utf-8')
        if not data:
            break
        buffer += data
        if '\n' in buffer:
            lines = buffer.split('\n')
            for line in lines[:-1]:  # Process all complete lines
                if line.strip():
                    print(f"Received: {line}")
                    return json.loads(line)
            buffer = lines[-1]  # Keep the incomplete line
    return None


def test_tcp_mcp_server():
    """Test the MCP server over TCP."""
    sock = None
    try:
        # Connect to the server
        print("Connecting to MCP server at 127.0.0.1:8080...")
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.connect(('127.0.0.1', 8080))
        print("Connected successfully!")

        # Test 1: Initialize
        print("\n=== Test 1: Initialize ===")
        init_request = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "clientInfo": {"name": "tcp-test-client", "version": "1.0.0"}
            }
        }
        send_json_request(sock, init_request)
        response = read_json_response(sock)
        if response:
            print(f"Initialize response: {json.dumps(response, indent=2)}")
        else:
            print("No response received for initialize")

        # Test 2: List tools
        print("\n=== Test 2: List Tools ===")
        list_tools_request = {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": {}
        }
        send_json_request(sock, list_tools_request)
        response = read_json_response(sock)
        if response:
            print(f"Tools list response: {json.dumps(response, indent=2)}")
        else:
            print("No response received for tools/list")        # Test 3: Call calculator tool
        print("\n=== Test 3: Call Calculator Tool ===")
        calc_request = {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "calculator",
                "arguments": {"operation": "add", "a": "2", "b": "8"}
            }
        }
        send_json_request(sock, calc_request)
        response = read_json_response(sock)
        if response:
            print(f"Calculator response: {json.dumps(response, indent=2)}")
        else:
            print("No response received for calculator")        # Test 4: Call CLI tool
        print("\n=== Test 4: Call CLI Tool ===")
        cli_request = {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {
                "name": "cli",
                "arguments": {"command": "echo", "args": "Hello World"}
            }
        }
        send_json_request(sock, cli_request)
        response = read_json_response(sock)
        if response:
            print(f"CLI response: {json.dumps(response, indent=2)}")
        else:
            print("No response received for CLI")

        print("\n=== All tests completed ===")

    except Exception as e:
        print(f"Error: {e}")
    finally:
        try:
            if sock is not None:
                sock.close()
        except:
            pass


if __name__ == "__main__":
    test_tcp_mcp_server()
