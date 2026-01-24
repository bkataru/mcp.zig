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
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,
    stream: ?net.Stream,
    id: u32,

    /// Close the connection
    pub fn close(self: *Connection) void {
        if (self.stream) |stream| {
            stream.close();
        }
    }
};

/// Network module handles all network communication for the MCP server
pub const Network = struct {
    // All fields must come first in Zig structs
    allocator: std.mem.Allocator,
    listener: ?net.Server,
    rpc_handler: *JsonRpc,
    connections: std.AutoHashMap(u32, Connection),
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
            .connections = std.AutoHashMap(u32, Connection).init(allocator),
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
            entry.value_ptr.close();
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
    ) !Connection {
        return switch (conn_type) {
            .stdio => Connection{
                .conn_type = .stdio,
                .reader = std.fs.File.stdin().reader().any(),
                .writer = std.fs.File.stdout().writer().any(),
                .stream = null,
                .id = 0,
            },
            .tcp => blk: {
                if (stream == null) return error.NoStreamProvided;
                const conn_id = self.next_conn_id;
                self.next_conn_id +%= 1;
                break :blk Connection{
                    .conn_type = .tcp,
                    .reader = stream.?.reader().any(),
                    .writer = stream.?.writer().any(),
                    .stream = stream,
                    .id = conn_id,
                };
            },
        };
    }

    /// Read a complete JSON message from connection
    pub fn readMessage(
        self: *Network,
        conn: *Connection,
    ) !json.Parsed(json.Value) {
        var buffer: [4096]u8 = undefined;
        const bytes_read = try conn.reader.readAll(&buffer);
        return json.parseFromSlice(
            json.Value,
            self.allocator,
            buffer[0..bytes_read],
            .{},
        );
    }

    /// Write a JSON message to connection
    pub fn writeMessage(
        self: *Network,
        conn: *Connection,
        message: json.Value,
    ) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        try json.stringify(message, .{}, buffer.writer());
        try conn.writer.writeAll(buffer.items);
    }

    /// Close a connection
    pub fn closeConnection(self: *Network, conn: *Connection) void {
        conn.close();
        _ = self.connections.remove(conn.id);
    }
};
