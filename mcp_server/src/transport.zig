const std = @import("std");
const builtin = @import("builtin");

/// Generic transport interface for MCP communication
/// Inspired by mcp-zig reference implementation
pub const Transport = struct {
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,
    mutex: std.Thread.Mutex = .{},

    /// Initialize transport from reader/writer pair
    pub fn init(reader: std.io.AnyReader, writer: std.io.AnyWriter) Transport {
        return .{
            .reader = reader,
            .writer = writer,
        };
    }

    /// Thread-safe write operation
    fn writeThreadSafe(self: *Transport, data: []const u8) anyerror!usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return try self.writer.write(data);
    }

    /// Get a thread-safe writer
    pub const Writer = std.io.GenericWriter(*Transport, anyerror, writeThreadSafe);
    pub fn getWriter(self: *Transport) Writer {
        return .{ .context = self };
    }

    /// Write a complete JSON-RPC message with proper formatting
    pub fn writeMessage(self: *Transport, message: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.log.debug("Transport: Writing message: {s}", .{message});

        try self.writer.writeAll(message);
        try self.writer.writeByte('\n');

        std.log.debug("Transport: Message written successfully", .{});
    }

    /// Read a complete JSON-RPC message
    pub fn readMessage(self: *Transport, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        std.log.debug("Transport: Starting to read message", .{});

        // Read line by line until we get a complete JSON message
        while (true) {
            const byte = self.reader.readByte() catch |err| switch (err) {
                error.EndOfStream => {
                    std.log.debug("Transport: EndOfStream reached, buffer length: {d}", .{buffer.items.len});
                    if (buffer.items.len > 0) break;
                    return err;
                },
                else => {
                    std.log.debug("Transport: Read error: {any}", .{err});
                    if (buffer.items.len > 0) break;
                    return err;
                },
            };

            if (byte == '\n') {
                // Found complete line
                break;
            } else if (byte != '\r') {
                // Add to buffer (skip carriage returns)
                try buffer.append(byte);
            }
        }

        // Trim whitespace and validate we have content
        const message = std.mem.trim(u8, buffer.items, " \t\r\n");
        if (message.len == 0) {
            std.log.debug("Transport: Empty message after trimming", .{});
            return error.EndOfStream;
        }

        const result = try allocator.dupe(u8, message);
        std.log.debug("Transport: Read message: {s}", .{result});
        return result;
    }

    /// Cleanup transport resources
    pub fn deinit(self: *Transport) void {
        _ = self; // Transport doesn't own the reader/writer, so nothing to cleanup
    }
};

/// Enhanced transport wrapper with fallback handling for problematic connections
pub const TransportWithFallback = struct {
    transport: *Transport,

    pub fn init(transport: *Transport) TransportWithFallback {
        return .{ .transport = transport };
    }

    /// Read message with enhanced error handling and fallback logic
    pub fn readMessageWithFallback(self: *TransportWithFallback, allocator: std.mem.Allocator) ![]u8 {
        const result = self.transport.readMessage(allocator) catch |err| switch (err) {
            error.EndOfStream => {
                std.log.info("Transport: Input stream closed or disconnected");
                return err;
            },
            error.Unexpected => {
                std.log.debug("Transport: Unexpected error, treating as disconnection");
                return error.EndOfStream;
            },
            error.BrokenPipe => {
                std.log.debug("Transport: Broken pipe detected");
                return error.EndOfStream;
            },
            else => {
                std.log.debug("Transport: Read error: {any}", .{err});
                return err;
            },
        };
        return result;
    }

    pub fn writeMessage(self: *TransportWithFallback, message: []const u8) !void {
        return self.transport.writeMessage(message);
    }
};

/// Stdio transport implementation with Windows pipe handling
pub const StdioTransport = struct {
    transport: Transport,

    pub fn init() StdioTransport {
        return StdioTransport{
            .transport = Transport{
                .reader = std.io.getStdIn().reader().any(),
                .writer = std.io.getStdOut().writer().any(),
            },
        };
    }

    pub fn deinit(self: *StdioTransport) void {
        _ = self; // No cleanup needed for stdio
    }

    /// Enhanced readMessage that handles Windows pipe closure gracefully
    pub fn readMessageWithFallback(self: *StdioTransport, allocator: std.mem.Allocator) ![]u8 {
        // On Windows, try immediate read without delays since pipe may close quickly
        if (builtin.os.tag == .windows) {
            const result = self.transport.readMessage(allocator) catch |err| switch (err) {
                error.EndOfStream, error.Unexpected, error.BrokenPipe => {
                    std.log.debug("Windows pipe closed gracefully", .{});
                    return error.EndOfStream;
                },
                else => return err,
            };

            return result;
        }

        return self.transport.readMessage(allocator);
    }
};

/// TCP transport implementation
pub const TcpTransport = struct {
    transport: Transport,
    stream: std.net.Stream,

    pub fn init(stream: std.net.Stream) TcpTransport {
        return TcpTransport{
            .transport = Transport{
                .reader = stream.reader().any(),
                .writer = stream.writer().any(),
            },
            .stream = stream,
        };
    }

    pub fn deinit(self: *TcpTransport) void {
        self.stream.close();
    }
};

/// Transport mode selection
pub const TransportMode = enum {
    stdio,
    tcp,
};

/// Parse command line arguments to determine transport mode
pub fn parseTransportMode(allocator: std.mem.Allocator) !TransportMode {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--stdio")) return .stdio;
        if (std.mem.eql(u8, arg, "--tcp")) return .tcp;
    }
    return .stdio; // Default to stdio for MCP compliance
}
