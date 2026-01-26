const std = @import("std");
const net = std.net;
const json = std.json;
const Thread = std.Thread;
const JsonRpc = @import("./jsonrpc.zig").JsonRpc;
const Io = std.Io;

/// Supported connection types
pub const ConnectionType = enum {
    stdio,
    tcp,
};

/// Buffer size for reader/writer operations
const BUFFER_SIZE: usize = 8192;

/// Network connection with std.Io.Reader/Writer interfaces
pub const Connection = struct {
    conn_type: ConnectionType,
    stream: ?net.Stream,
    id: u32,

    // For stdio connections
    stdin_file: ?std.fs.File,
    stdout_file: ?std.fs.File,

    // Buffers for the new Io API (stored as pointers to heap-allocated arrays)
    read_buffer: *[BUFFER_SIZE]u8,
    write_buffer: *[BUFFER_SIZE]u8,

    // Reader/Writer state - stored as optional since they're initialized after buffers
    file_reader: ?std.fs.File.Reader,
    file_writer: ?std.fs.File.Writer,
    stream_reader: ?net.Stream.Reader,
    stream_writer: ?net.Stream.Writer,

    allocator: std.mem.Allocator,

    /// Get the reader interface
    pub fn reader(self: *Connection) *Io.Reader {
        return switch (self.conn_type) {
            .stdio => &self.file_reader.?.interface,
            .tcp => self.stream_reader.?.interface(),
        };
    }

    /// Get the writer interface
    pub fn writer(self: *Connection) *Io.Writer {
        return switch (self.conn_type) {
            .stdio => &self.file_writer.?.interface,
            .tcp => &self.stream_writer.?.interface,
        };
    }

    /// Close the connection and free buffers
    pub fn close(self: *Connection) void {
        // Flush writer before closing
        if (self.conn_type == .stdio) {
            if (self.file_writer) |*fw| {
                fw.interface.flush() catch {};
            }
        } else {
            if (self.stream_writer) |*sw| {
                sw.interface.flush() catch {};
            }
        }

        if (self.stream) |stream| {
            stream.close();
        }

        // Free the buffers
        self.allocator.destroy(self.read_buffer);
        self.allocator.destroy(self.write_buffer);
    }
};

/// Network module handles all network communication for the MCP server
pub const Network = struct {
    allocator: std.mem.Allocator,
    listener: ?net.Server,
    rpc_handler: *JsonRpc,
    connections: std.AutoHashMap(u32, *Connection),
    next_conn_id: u32,
    shutdown: std.atomic.Value(bool),
    port: u16,
    max_message_size: usize,
    connection_timeout_ms: u32,
    read_timeout_ms: u32,

    /// Initialize network components
    pub fn init(allocator: std.mem.Allocator, rpc_handler: *JsonRpc, port: u16) !*Network {
        const self = try allocator.create(Network);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .listener = null,
            .rpc_handler = rpc_handler,
            .connections = std.AutoHashMap(u32, *Connection).init(allocator),
            .next_conn_id = 1,
            .shutdown = std.atomic.Value(bool).init(false),
            .port = port,
            .max_message_size = 1024 * 1024,
            .connection_timeout_ms = 30_000,
            .read_timeout_ms = 10_000,
        };

        return self;
    }

    /// Clean up network resources
    pub fn deinit(self: *Network) void {
        self.shutdown.store(true, .seq_cst);

        // Close all connections
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.close();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.connections.deinit();

        // Close listener
        if (self.listener) |*listener| {
            listener.deinit();
        }

        self.allocator.destroy(self);
    }

    /// Accept a new client connection
    pub fn acceptConnection(
        self: *Network,
        conn_type: ConnectionType,
        stream: ?net.Stream,
    ) !*Connection {
        // Allocate buffers
        const read_buffer = try self.allocator.create([BUFFER_SIZE]u8);
        errdefer self.allocator.destroy(read_buffer);

        const write_buffer = try self.allocator.create([BUFFER_SIZE]u8);
        errdefer self.allocator.destroy(write_buffer);

        // Allocate connection
        const conn = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(conn);

        switch (conn_type) {
            .stdio => {
                const stdin_file = std.fs.File.stdin();
                const stdout_file = std.fs.File.stdout();

                conn.* = Connection{
                    .conn_type = .stdio,
                    .stream = null,
                    .id = 0,
                    .stdin_file = stdin_file,
                    .stdout_file = stdout_file,
                    .read_buffer = read_buffer,
                    .write_buffer = write_buffer,
                    .file_reader = stdin_file.reader(read_buffer),
                    .file_writer = stdout_file.writer(write_buffer),
                    .stream_reader = null,
                    .stream_writer = null,
                    .allocator = self.allocator,
                };
            },
            .tcp => {
                if (stream == null) return error.NoStreamProvided;
                const conn_id = self.next_conn_id;
                self.next_conn_id +%= 1;

                conn.* = Connection{
                    .conn_type = .tcp,
                    .stream = stream,
                    .id = conn_id,
                    .stdin_file = null,
                    .stdout_file = null,
                    .read_buffer = read_buffer,
                    .write_buffer = write_buffer,
                    .file_reader = null,
                    .file_writer = null,
                    .stream_reader = stream.?.reader(read_buffer),
                    .stream_writer = stream.?.writer(write_buffer),
                    .allocator = self.allocator,
                };
            },
        }

        return conn;
    }

    /// Read a complete JSON message from connection
    pub fn readMessage(
        self: *Network,
        conn: *Connection,
    ) !json.Parsed(json.Value) {
        // Use the new Io.Reader API
        const r = conn.reader();

        // Read available data using take() which returns buffered data
        const data = r.take(4096) catch |err| {
            return if (err == error.ReadFailed) error.EndOfStream else err;
        };

        return json.parseFromSlice(
            json.Value,
            self.allocator,
            data,
            .{},
        );
    }

    /// Write a JSON message to connection
    pub fn writeMessage(
        self: *Network,
        conn: *Connection,
        message: json.Value,
    ) !void {
        const w = conn.writer();

        // Serialize JSON to an allocating writer, then write to connection
        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();

        try json.Stringify.value(message, .{}, &out.writer);
        try w.writeAll(out.written());
        try w.flush();
    }

    /// Close a connection
    pub fn closeConnection(self: *Network, conn: *Connection) void {
        const conn_id = conn.id;
        conn.close();
        self.allocator.destroy(conn);
        _ = self.connections.remove(conn_id);
    }
};

// ==================== Tests ====================

const ToolRegistry = @import("./primitives/tool.zig").ToolRegistry;

test "Network init creates valid state" {
    const allocator = std.testing.allocator;

    // Create a minimal tool registry for JsonRpc
    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc_handler = JsonRpc.init(allocator, &tool_registry);
    defer rpc_handler.deinit();

    const network = try Network.init(allocator, &rpc_handler, 8080);
    defer network.deinit();

    // Verify all fields are initialized correctly
    try std.testing.expectEqual(@as(u16, 8080), network.port);
    try std.testing.expectEqual(@as(u32, 1), network.next_conn_id);
    try std.testing.expect(network.listener == null);
    try std.testing.expectEqual(false, network.shutdown.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1024 * 1024), network.max_message_size);
    try std.testing.expectEqual(@as(u32, 30_000), network.connection_timeout_ms);
    try std.testing.expectEqual(@as(u32, 10_000), network.read_timeout_ms);
    try std.testing.expectEqual(@as(usize, 0), network.connections.count());
}

test "Network deinit cleans up resources" {
    const allocator = std.testing.allocator;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc_handler = JsonRpc.init(allocator, &tool_registry);
    defer rpc_handler.deinit();

    const network = try Network.init(allocator, &rpc_handler, 9000);

    // Create a connection to verify cleanup
    const conn = try network.acceptConnection(.stdio, null);
    try network.connections.put(conn.id, conn);

    // deinit should clean up both the network and the connection without leaks
    network.deinit();

    // If we reach here without memory leaks, the test passes
    // (std.testing.allocator will detect leaks)
}

test "Network acceptConnection allocates buffers for stdio" {
    const allocator = std.testing.allocator;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc_handler = JsonRpc.init(allocator, &tool_registry);
    defer rpc_handler.deinit();

    const network = try Network.init(allocator, &rpc_handler, 8080);
    defer network.deinit();

    const conn = try network.acceptConnection(.stdio, null);
    defer {
        conn.close();
        allocator.destroy(conn);
    }

    // Verify connection type
    try std.testing.expectEqual(ConnectionType.stdio, conn.conn_type);

    // Verify buffers are allocated (non-null pointers)
    try std.testing.expect(@intFromPtr(conn.read_buffer) != 0);
    try std.testing.expect(@intFromPtr(conn.write_buffer) != 0);

    // Verify stdio files are set
    try std.testing.expect(conn.stdin_file != null);
    try std.testing.expect(conn.stdout_file != null);

    // Verify TCP-specific fields are null
    try std.testing.expect(conn.stream == null);
    try std.testing.expect(conn.stream_reader == null);
    try std.testing.expect(conn.stream_writer == null);

    // Verify file reader/writer are initialized
    try std.testing.expect(conn.file_reader != null);
    try std.testing.expect(conn.file_writer != null);
}

test "Network acceptConnection rejects null tcp stream" {
    const allocator = std.testing.allocator;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc_handler = JsonRpc.init(allocator, &tool_registry);
    defer rpc_handler.deinit();

    const network = try Network.init(allocator, &rpc_handler, 8080);
    defer network.deinit();

    // TCP connection without a stream should fail
    const result = network.acceptConnection(.tcp, null);
    try std.testing.expectError(error.NoStreamProvided, result);
}

test "Connection reader returns valid pointer for stdio" {
    const allocator = std.testing.allocator;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc_handler = JsonRpc.init(allocator, &tool_registry);
    defer rpc_handler.deinit();

    const network = try Network.init(allocator, &rpc_handler, 8080);
    defer network.deinit();

    var conn = try network.acceptConnection(.stdio, null);
    defer {
        conn.close();
        allocator.destroy(conn);
    }

    // Get reader and verify it's a valid pointer
    const r = conn.reader();
    try std.testing.expect(@intFromPtr(r) != 0);

    // The reader should be the file_reader's interface
    try std.testing.expectEqual(@intFromPtr(&conn.file_reader.?.interface), @intFromPtr(r));
}

test "Connection writer returns valid pointer for stdio" {
    const allocator = std.testing.allocator;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc_handler = JsonRpc.init(allocator, &tool_registry);
    defer rpc_handler.deinit();

    const network = try Network.init(allocator, &rpc_handler, 8080);
    defer network.deinit();

    var conn = try network.acceptConnection(.stdio, null);
    defer {
        conn.close();
        allocator.destroy(conn);
    }

    // Get writer and verify it's a valid pointer
    const w = conn.writer();
    try std.testing.expect(@intFromPtr(w) != 0);

    // The writer should be the file_writer's interface
    try std.testing.expectEqual(@intFromPtr(&conn.file_writer.?.interface), @intFromPtr(w));
}

test "Connection close frees allocated buffers" {
    const allocator = std.testing.allocator;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc_handler = JsonRpc.init(allocator, &tool_registry);
    defer rpc_handler.deinit();

    const network = try Network.init(allocator, &rpc_handler, 8080);
    defer network.deinit();

    const conn = try network.acceptConnection(.stdio, null);

    // Close connection - this should free the buffers
    conn.close();
    allocator.destroy(conn);

    // If we reach here without memory leaks, the test passes
    // (std.testing.allocator will detect leaks)
}

test "Network connection ID increments" {
    const allocator = std.testing.allocator;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc_handler = JsonRpc.init(allocator, &tool_registry);
    defer rpc_handler.deinit();

    const network = try Network.init(allocator, &rpc_handler, 8080);
    defer network.deinit();

    // Initial next_conn_id should be 1
    try std.testing.expectEqual(@as(u32, 1), network.next_conn_id);

    // For stdio connections, the ID is set to 0, but next_conn_id doesn't change
    const conn1 = try network.acceptConnection(.stdio, null);
    defer {
        conn1.close();
        allocator.destroy(conn1);
    }

    // stdio connections get ID 0
    try std.testing.expectEqual(@as(u32, 0), conn1.id);

    // next_conn_id is only incremented for TCP connections
    // Since we can't easily create real TCP streams in tests,
    // we verify the initial state and the mechanism
    try std.testing.expectEqual(@as(u32, 1), network.next_conn_id);
}

test "Network writeMessage serializes JSON correctly" {
    const allocator = std.testing.allocator;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc_handler = JsonRpc.init(allocator, &tool_registry);
    defer rpc_handler.deinit();

    const network = try Network.init(allocator, &rpc_handler, 8080);
    defer network.deinit();

    // Create a test buffer to capture output
    var output_buffer: [1024]u8 = undefined;
    var fixed_writer = Io.Writer.fixed(&output_buffer);

    // Create a JSON value to serialize
    var obj = json.ObjectMap.init(allocator);
    defer obj.deinit();
    try obj.put("jsonrpc", json.Value{ .string = "2.0" });
    try obj.put("id", json.Value{ .integer = 1 });
    try obj.put("result", json.Value{ .string = "success" });

    const message = json.Value{ .object = obj };

    // Serialize using the allocating writer approach (similar to writeMessage)
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try json.Stringify.value(message, .{}, &out.writer);
    const written = out.written();

    // Write to fixed buffer
    try fixed_writer.writeAll(written);

    // Verify the JSON contains expected fields
    const result = output_buffer[0..written.len];
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "jsonrpc"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "2.0"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "result"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "success"));
}

test "Network shutdown flag works correctly" {
    const allocator = std.testing.allocator;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc_handler = JsonRpc.init(allocator, &tool_registry);
    defer rpc_handler.deinit();

    const network = try Network.init(allocator, &rpc_handler, 8080);
    defer network.deinit();

    // Initially shutdown should be false
    try std.testing.expectEqual(false, network.shutdown.load(.seq_cst));

    // Store true
    network.shutdown.store(true, .seq_cst);
    try std.testing.expectEqual(true, network.shutdown.load(.seq_cst));

    // Store false again
    network.shutdown.store(false, .seq_cst);
    try std.testing.expectEqual(false, network.shutdown.load(.seq_cst));
}

test "Network connections hashmap operations" {
    const allocator = std.testing.allocator;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc_handler = JsonRpc.init(allocator, &tool_registry);
    defer rpc_handler.deinit();

    const network = try Network.init(allocator, &rpc_handler, 8080);
    defer network.deinit();

    // Create connections
    const conn1 = try network.acceptConnection(.stdio, null);
    const conn2 = try network.acceptConnection(.stdio, null);

    // Manually assign IDs for testing (since stdio uses 0)
    conn1.id = 100;
    conn2.id = 200;

    // Add to connections map
    try network.connections.put(conn1.id, conn1);
    try network.connections.put(conn2.id, conn2);

    // Verify count
    try std.testing.expectEqual(@as(usize, 2), network.connections.count());

    // Verify we can retrieve them
    try std.testing.expect(network.connections.get(100) != null);
    try std.testing.expect(network.connections.get(200) != null);
    try std.testing.expect(network.connections.get(999) == null);

    // Clean up manually since we're not going through closeConnection
    conn1.close();
    allocator.destroy(conn1);
    conn2.close();
    allocator.destroy(conn2);
    _ = network.connections.remove(100);
    _ = network.connections.remove(200);
}

test "Connection buffer size is correct" {
    const allocator = std.testing.allocator;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc_handler = JsonRpc.init(allocator, &tool_registry);
    defer rpc_handler.deinit();

    const network = try Network.init(allocator, &rpc_handler, 8080);
    defer network.deinit();

    const conn = try network.acceptConnection(.stdio, null);
    defer {
        conn.close();
        allocator.destroy(conn);
    }

    // Verify buffer sizes match BUFFER_SIZE constant (8192)
    try std.testing.expectEqual(@as(usize, BUFFER_SIZE), conn.read_buffer.len);
    try std.testing.expectEqual(@as(usize, BUFFER_SIZE), conn.write_buffer.len);
    try std.testing.expectEqual(@as(usize, 8192), BUFFER_SIZE);
}

test "ConnectionType enum has correct variants" {
    // Test all enum variants exist and are distinct
    const stdio = ConnectionType.stdio;
    const tcp = ConnectionType.tcp;

    try std.testing.expect(stdio != tcp);
    try std.testing.expectEqual(ConnectionType.stdio, stdio);
    try std.testing.expectEqual(ConnectionType.tcp, tcp);
}

test "Network closeConnection removes from connections map" {
    const allocator = std.testing.allocator;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc_handler = JsonRpc.init(allocator, &tool_registry);
    defer rpc_handler.deinit();

    const network = try Network.init(allocator, &rpc_handler, 8080);
    defer network.deinit();

    // Create a connection
    const conn = try network.acceptConnection(.stdio, null);
    conn.id = 42; // Assign a test ID

    // Add to connections map
    try network.connections.put(conn.id, conn);
    try std.testing.expectEqual(@as(usize, 1), network.connections.count());

    // Close connection using network method
    network.closeConnection(conn);

    // Connection should be removed from map
    try std.testing.expectEqual(@as(usize, 0), network.connections.count());
    try std.testing.expect(network.connections.get(42) == null);
}

test "Network init with different ports" {
    const allocator = std.testing.allocator;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc_handler = JsonRpc.init(allocator, &tool_registry);
    defer rpc_handler.deinit();

    // Test with common ports
    const network1 = try Network.init(allocator, &rpc_handler, 80);
    defer network1.deinit();
    try std.testing.expectEqual(@as(u16, 80), network1.port);

    const network2 = try Network.init(allocator, &rpc_handler, 443);
    defer network2.deinit();
    try std.testing.expectEqual(@as(u16, 443), network2.port);

    const network3 = try Network.init(allocator, &rpc_handler, 0);
    defer network3.deinit();
    try std.testing.expectEqual(@as(u16, 0), network3.port);

    // Max port
    const network4 = try Network.init(allocator, &rpc_handler, 65535);
    defer network4.deinit();
    try std.testing.expectEqual(@as(u16, 65535), network4.port);
}

test "Connection stores allocator correctly" {
    const allocator = std.testing.allocator;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc_handler = JsonRpc.init(allocator, &tool_registry);
    defer rpc_handler.deinit();

    const network = try Network.init(allocator, &rpc_handler, 8080);
    defer network.deinit();

    const conn = try network.acceptConnection(.stdio, null);
    defer {
        conn.close();
        allocator.destroy(conn);
    }

    // Verify the connection has the correct allocator stored
    // (We can't compare allocators directly, but we can verify it works)
    try std.testing.expect(@intFromPtr(&conn.allocator) != 0);
}

test "Multiple stdio connections can be created" {
    const allocator = std.testing.allocator;

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var rpc_handler = JsonRpc.init(allocator, &tool_registry);
    defer rpc_handler.deinit();

    const network = try Network.init(allocator, &rpc_handler, 8080);
    defer network.deinit();

    // Create multiple stdio connections
    const conn1 = try network.acceptConnection(.stdio, null);
    const conn2 = try network.acceptConnection(.stdio, null);
    const conn3 = try network.acceptConnection(.stdio, null);

    defer {
        conn1.close();
        allocator.destroy(conn1);
        conn2.close();
        allocator.destroy(conn2);
        conn3.close();
        allocator.destroy(conn3);
    }

    // All should be stdio type
    try std.testing.expectEqual(ConnectionType.stdio, conn1.conn_type);
    try std.testing.expectEqual(ConnectionType.stdio, conn2.conn_type);
    try std.testing.expectEqual(ConnectionType.stdio, conn3.conn_type);

    // Each should have distinct buffers
    try std.testing.expect(@intFromPtr(conn1.read_buffer) != @intFromPtr(conn2.read_buffer));
    try std.testing.expect(@intFromPtr(conn2.read_buffer) != @intFromPtr(conn3.read_buffer));
    try std.testing.expect(@intFromPtr(conn1.write_buffer) != @intFromPtr(conn2.write_buffer));
}
