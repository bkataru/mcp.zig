#!/usr/bin/env python3
"""
Test both echo and ls commands to verify CLI tool works with different commands.
"""
import socket
import json
import time

def send_request(sock, request):
    message = json.dumps(request) + "\n"
    sock.send(message.encode())
    
    # Read response with buffer for large outputs
    response = b""
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        response += chunk
        try:
            # Try to parse as complete JSON
            response_str = response.decode()
            return json.loads(response_str)
        except (json.JSONDecodeError, UnicodeDecodeError):
            # Continue reading if not complete
            continue

def test_cli_commands():
    print("Testing CLI tool with multiple commands...")
    
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.connect(('127.0.0.1', 8080))
        
        # Test echo command
        print("\n=== Testing echo command ===")
        echo_request = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "cli",
                "arguments": {
                    "command": "echo",
                    "args": "Hello from echo!"
                }
            }
        }
          response = send_request(sock, echo_request)
        if response and 'result' in response:
            content = response['result']['content'][0]['text']
            print(f"Echo output: {repr(content)}")
            if "Hello from echo!" in content:
                print("✅ Echo command working")
            else:
                print("❌ Echo command failed")
        else:
            print("❌ Echo command failed - no response")
        
        # Test ls command (using dir on Windows via cmd.exe)
        print("\n=== Testing ls command ===")
        ls_request = {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": "cli",
                "arguments": {
                    "command": "ls",
                    "args": ""
                }
            }
        }
        
        response = send_request(sock, ls_request)
        if 'result' in response:
            content = response['result']['content'][0]['text']
            print(f"Ls output length: {len(content)} chars")
            print(f"First 100 chars: {repr(content[:100])}")
            if len(content) > 10:  # Should have some directory listing content
                print("✅ Ls command working")
            else:
                print("❌ Ls command failed or no output")
        
    except Exception as e:
        print(f"❌ Error testing CLI commands: {e}")
    finally:
        sock.close()

if __name__ == "__main__":
    test_cli_commands()
