#!/usr/bin/env python3
"""
Simple test script to verify CLI tool output capture is working correctly.
"""
import socket
import json
import time

def test_cli_tool():
    print("Testing CLI tool output capture...")
    
    # Connect to server
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.connect(('127.0.0.1', 8080))
        
        # Test echo command
        request = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "cli",
                "arguments": {
                    "command": "echo",
                    "args": "CLI tool working!"
                }
            }
        }
        
        message = json.dumps(request) + "\n"
        sock.send(message.encode())
        
        response = sock.recv(4096).decode()
        print(f"Response: {response}")
        
        # Parse response
        response_data = json.loads(response)
        if 'result' in response_data and 'content' in response_data['result']:
            content = response_data['result']['content'][0]['text']
            print(f"CLI output: {repr(content)}")
            if "CLI tool working!" in content:
                print("✅ CLI tool output capture is working correctly!")
                return True
            else:
                print("❌ CLI tool output not captured correctly")
                return False
        else:
            print("❌ Unexpected response format")
            return False
            
    except Exception as e:
        print(f"❌ Error testing CLI tool: {e}")
        return False
    finally:
        sock.close()

if __name__ == "__main__":
    test_cli_tool()
