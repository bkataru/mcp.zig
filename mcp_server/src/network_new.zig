const std = @import("std");
const net = std.net;
const json = std.json;
const Thread = std.Thread;
const JsonRpc = @import("./jsonrpc.zig").JsonRpc;

/// Supported connection types
pub const ConnectionType = enum {
    stdio,
    tcp,
};

/// Network connection with Reader/Writer interfaces
pub const Connection = struct {
    conn_type: ConnectionType,
    reader: std.io.Reader(*std.fs.File, std.fs.File.ReadError, struct {
        fn read(file: *std.fs.File, buffer: []u8) std.fs.File.ReadError!usize {
            return file.read(buffer);
        }
    }.read),
    writer: std.io.Writer(*std.fs.File, std.fs.File.WriteError, struct {
        fn write(file: *std.fs.File, bytes: []const u8) std.fs.File.WriteError!usize {
            return file.write(bytes);
        }
    }.write),
    stream: ?net.Stream,
    id: u32,

    /// Close the connection
    pub fn close(self: *Connection) void {
        if (self.stream) |*stream| {
            stream.close();
        }
    }
};

/// Network module handles all network communication for the MCP server
pub const Network = struct {
    allocator: std.mem.Allocator,
    listener: ?net.Server = null,
    rpc_handler: *JsonRpc,
    connections: std.AutoHashMap(u32, Connection),
    next_conn_id: u32 = 1,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    port: u16 = 8080,
    max_message_size: usize = 1024 * 1024, // 1MB
    connection_timeout_ms: u32 = 30_000, // 30 seconds
    read_timeout_ms: u32 = 10_000, // 10 seconds

    /// Initialize network components
    pub fn init(allocator: std.mem.Allocator, rpc_handler: *JsonRpc, port: u16) !Network {
        return Network{
            .allocator = allocator,
            .rpc_handler = rpc_handler,
            .connections = std.AutoHashMap(u32, Connection).init(allocator),
            .port = port,
        };
    }

    /// Start the network server
    pub fn start(self: *Network) !void {
        std.log.info("Starting network server on port {}", .{self.port});
        try self.startTcpListener();
        std.log.info("Network server started successfully", .{});
    }

    /// Stop the network server
    pub fn stop(self: *Network) void {
        std.log.info("Stopping network server...", .{});
        self.shutdown.store(true, .seq_cst);

        // Close all connections
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.close();
        }

        // Close listener
        if (self.listener) |*listener| {
            listener.deinit();
            self.listener = null;
        }

        std.log.info("Network server stopped", .{});
    }

    /// Clean up network resources
    pub fn deinit(self: *Network) void {
        self.stop();
        self.connections.deinit();
    }

    fn startTcpListener(self: *Network) !void {
        const address = try net.Address.parseIp("0.0.0.0", self.port);
        var listener = try address.listen(.{});
        self.listener = listener;

        // Spawn listener thread
        _ = try Thread.spawn(.{}, handleIncomingConnections, .{self});
    }

    /// Handle incoming connections
    fn handleIncomingConnections(network_ref: *Network) !void {
        std.log.info("Connection handler thread started", .{});

        while (!network_ref.shutdown.load(.seq_cst)) {
            if (network_ref.listener) |*listener| {
                const connection = listener.accept() catch |err| switch (err) {
                    error.WouldBlock => {
                        std.time.sleep(10_000_000); // 10ms
                        continue;
                    },
                    else => {
                        std.log.err("Failed to accept connection: {}", .{err});
                        continue;
                    },
                };

                // Handle the connection
                network_ref.handleConnection(connection) catch |err| {
                    std.log.err("Failed to handle connection: {}", .{err});
                    connection.stream.close();
                };
            } else {
                break;
            }
        }

        std.log.info("Connection handler thread stopped", .{});
    }

    /// Handle a single connection
    fn handleConnection(self: *Network, connection: net.Server.Connection) !void {
        const conn_id = self.next_conn_id;
        self.next_conn_id += 1;

        std.log.info("New connection accepted: ID {}", .{conn_id});

        const conn = Connection{
            .conn_type = .tcp,
            .reader = undefined, // TODO: Set up proper reader
            .writer = undefined, // TODO: Set up proper writer
            .stream = connection.stream,
            .id = conn_id,
        };

        try self.connections.put(conn_id, conn);

        // Spawn connection handler thread
        const thread_data = ConnectionThreadData{
            .network = self,
            .connection_id = conn_id,
        };

        _ = try Thread.spawn(.{}, handleConnectionMessages, .{thread_data});
    }

    /// Data passed to connection thread
    const ConnectionThreadData = struct {
        network: *Network,
        connection_id: u32,
    };

    /// Handle messages for a specific connection
    fn handleConnectionMessages(data: ConnectionThreadData) !void {
        defer {
            // Clean up connection when thread exits
            if (data.network.connections.getPtr(data.connection_id)) |conn| {
                conn.close();
                _ = data.network.connections.remove(data.connection_id);
            }
            std.log.info("Connection {} handler thread stopped", .{data.connection_id});
        }

        std.log.info("Connection {} handler thread started", .{data.connection_id});

        const conn = data.network.connections.getPtr(data.connection_id) orelse return;

        var buffer: [4096]u8 = undefined;
        while (!data.network.shutdown.load(.seq_cst)) {
            if (conn.stream) |stream| {
                const bytes_read = stream.read(&buffer) catch |err| switch (err) {
                    error.EndOfStream => {
                        std.log.info("Connection {} closed by client", .{data.connection_id});
                        break;
                    },
                    else => {
                        std.log.err("Failed to read from connection {}: {}", .{ data.connection_id, err });
                        break;
                    },
                };

                if (bytes_read == 0) {
                    std.log.info("Connection {} closed (0 bytes read)", .{data.connection_id});
                    break;
                }

                const message = buffer[0..bytes_read];
                std.log.debug("Received {} bytes from connection {}: {s}", .{ bytes_read, data.connection_id, message });

                // Process the message through JSON-RPC handler
                const response = data.network.rpc_handler.handleRequest(message) catch |err| {
                    std.log.err("Failed to handle JSON-RPC request: {}", .{err});
                    continue;
                };

                // Send response back
                if (response) |resp| {
                    defer data.network.allocator.free(resp);
                    _ = stream.writeAll(resp) catch |err| {
                        std.log.err("Failed to send response to connection {}: {}", .{ data.connection_id, err });
                        break;
                    };
                }
            } else {
                break;
            }
        }
    }

    /// Send a message to a specific connection
    pub fn sendMessage(self: *Network, connection_id: u32, message: []const u8) !void {
        const conn = self.connections.getPtr(connection_id) orelse return error.ConnectionNotFound;

        if (conn.stream) |stream| {
            try stream.writeAll(message);
            std.log.debug("Sent {} bytes to connection {}: {s}", .{ message.len, connection_id, message });
        } else {
            return error.InvalidConnection;
        }
    }

    /// Broadcast a message to all connections
    pub fn broadcastMessage(self: *Network, message: []const u8) void {
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            self.sendMessage(entry.key_ptr.*, message) catch |err| {
                std.log.err("Failed to send message to connection {}: {}", .{ entry.key_ptr.*, err });
            };
        }
    }

    /// Get connection statistics
    pub fn getStats(self: *Network) struct {
        active_connections: u32,
        total_connections: u32,
        port: u16,
    } {
        return .{
            .active_connections = @intCast(self.connections.count()),
            .total_connections = self.next_conn_id - 1,
            .port = self.port,
        };
    }
};
