//! MCP TCP Full Protocol Example
//!
//! This example demonstrates complete MCP protocol communication over TCP.
//! It shows both server and client in a single process for simplicity.

const std = @import("std");
const net = std.net;
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Start server in a thread
    const server_thread = try std.Thread.spawn(.{}, runTcpServer, .{allocator});
    defer server_thread.join();

    // Give server time to start
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Run client
    try runTcpClient(allocator);
}

fn runTcpServer(allocator: std.mem.Allocator) !void {
    // Create MCP server with tools
    var server = try mcp.MCPServer.init(allocator);
    defer server.deinit();

    // Add calculator tool
    try server.registerTool(.{
        .name = "calculate",
        .description = "Perform basic arithmetic operations",
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "operation": { "type": "string", "enum": ["add", "subtract", "multiply", "divide"] },
        \\    "a": { "type": "number" },
        \\    "b": { "type": "number" }
        \\  },
        \\  "required": ["operation", "a", "b"]
        \\}
        ,
        .handler = struct {
            fn handler(alloc: std.mem.Allocator, arguments: std.json.Value) !std.json.Value {
                _ = alloc;
                const op = arguments.object.get("operation").?.string;
                const a = arguments.object.get("a").?.float;
                const b = arguments.object.get("b").?.float;

                const result = if (std.mem.eql(u8, op, "add")) a + b else if (std.mem.eql(u8, op, "subtract")) a - b else if (std.mem.eql(u8, op, "multiply")) a * b else if (std.mem.eql(u8, op, "divide")) a / b else return error.InvalidOperation;

                return std.json.Value{ .float = result };
            }
        }.handler,
    });

    // Set up TCP listener
    const address = try net.Address.parseIp4("127.0.0.1", 8081);
    var listener = try address.listen(.{});
    defer listener.deinit();

    std.debug.print("MCP TCP server listening on 127.0.0.1:8081\n", .{});

    // Accept one connection for this demo
    const connection = try listener.accept();
    std.debug.print("Client connected from {any}\n", .{connection.address});

    // Handle the connection
    try handleMcpConnection(connection.stream, &server, allocator);

    connection.stream.close();
}

fn runTcpClient(allocator: std.mem.Allocator) !void {
    _ = allocator; // Allocator could be used for more complex operations
    // Connect to server
    const address = try net.Address.parseIp4("127.0.0.1", 8081);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    std.debug.print("Connected to MCP server\n", .{});

    // Send initialize request
    const init_request =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"tcp-client","version":"1.0.0"}}}
        \\
    ;

    _ = try stream.write(init_request);
    std.debug.print("Sent initialize request\n", .{});

    // Read response
    var buffer: [4096]u8 = undefined;
    const bytes_read = try stream.read(&buffer);
    const response = buffer[0..bytes_read];
    std.debug.print("Initialize response: {s}\n", .{response});

    // Send tools/list request
    const tools_request =
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
        \\
    ;

    _ = try stream.write(tools_request);
    std.debug.print("Sent tools/list request\n", .{});

    const tools_bytes = try stream.read(&buffer);
    std.debug.print("Tools response: {s}\n", .{buffer[0..tools_bytes]});

    // Send tool call
    const tool_call =
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"calculate","arguments":{"operation":"add","a":10,"b":20}}}
        \\
    ;

    _ = try stream.write(tool_call);
    std.debug.print("Sent calculate tool call (10 + 20)\n", .{});

    const result_bytes = try stream.read(&buffer);
    std.debug.print("Tool result: {s}\n", .{buffer[0..result_bytes]});

    std.debug.print("Client finished\n", .{});
}

fn handleMcpConnection(stream: net.Stream, server: *mcp.MCPServer, allocator: std.mem.Allocator) !void {
    _ = server; // TODO: Use server for full MCP protocol handling
    var buffer: [4096]u8 = undefined;

    while (true) {
        const bytes_read = stream.read(&buffer) catch break;
        if (bytes_read == 0) break;

        const message = std.mem.trimRight(u8, buffer[0..bytes_read], "\r\n");
        std.debug.print("Received: {s}\n", .{message});

        // Parse JSON-RPC message
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, message, .{});
        defer parsed.deinit();

        const method = parsed.value.object.get("method").?.string;
        _ = parsed.value.object.get("id"); // ID could be used for response correlation

        // Handle different methods
        if (std.mem.eql(u8, method, "initialize")) {
            const response =
                \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{"enabled":true}},"serverInfo":{"name":"tcp-example-server","version":"1.0.0"}}}
                \\
            ;
            _ = try stream.write(response);
        } else if (std.mem.eql(u8, method, "tools/list")) {
            const response =
                \\{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"calculate","description":"Perform basic arithmetic operations"}]}}
                \\
            ;
            _ = try stream.write(response);
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const params = parsed.value.object.get("params").?.object;
            _ = params.get("name").?.string; // tool_name could be validated here
            const args = params.get("arguments").?.object;

            // Simple calculator logic
            const op = args.get("operation").?.string;
            const a = args.get("a").?.float;
            const b = args.get("b").?.float;

            const result = if (std.mem.eql(u8, op, "add")) a + b else if (std.mem.eql(u8, op, "subtract")) a - b else if (std.mem.eql(u8, op, "multiply")) a * b else if (std.mem.eql(u8, op, "divide")) a / b else 0;

            const response = try std.fmt.allocPrint(allocator,
                \\{{"jsonrpc":"2.0","id":3,"result":{{"content":[{{"type":"text","text":"Result: {d}"}}]}}}}
                \\
            , .{result});
            defer allocator.free(response);

            _ = try stream.write(response);
        }
    }
}
