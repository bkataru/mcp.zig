#!/usr/bin/env python3
"""
Simple test to verify both CLI commands work.
"""
import socket
import json

def test_cli():
    print("Testing CLI tool commands...")
    
    # Test 1: Echo command  
    print("\n=== Testing echo ===")
    sock1 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock1.connect(('127.0.0.1', 8080))
        
        echo_msg = json.dumps({
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "cli", "arguments": {"command": "echo", "args": "test"}}
        }) + "\n"
        
        sock1.send(echo_msg.encode())
        echo_response = sock1.recv(8192).decode()
        print(f"Echo response: {echo_response}")
        
        if '"test"' in echo_response:
            print("✅ Echo working")
    except Exception as e:
        print(f"Echo error: {e}")
    finally:
        sock1.close()
        
    # Test 2: LS command - use a new connection
    print("\n=== Testing ls ===") 
    sock2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock2.connect(('127.0.0.1', 8080))
        sock2.settimeout(5.0)  # 5 second timeout
        
        ls_msg = json.dumps({
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": "cli", "arguments": {"command": "ls", "args": ""}}
        }) + "\n"
        
        sock2.send(ls_msg.encode())
        
        # Read response in chunks to handle large output
        response_data = b""
        while True:
            chunk = sock2.recv(4096)
            if not chunk:
                break
            response_data += chunk
            
            # Check if we have a complete JSON response
            try:
                response_str = response_data.decode()
                if response_str.endswith('\n'):
                    response_json = json.loads(response_str.strip())
                    print(f"Ls response length: {len(response_str)}")
                    if "Directory of" in response_str and "build.zig" in response_str:
                        print("✅ Ls working")
                    else:
                        print("❌ Ls failed - unexpected content")
                    break
            except (json.JSONDecodeError, UnicodeDecodeError):
                # Continue reading
                continue
    except socket.timeout:
        print("❌ Ls command timed out")
    except Exception as e:
        print(f"Ls error: {e}")
    finally:
        sock2.close()

if __name__ == "__main__":
    test_cli()
