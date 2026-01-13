const std = @import("std");
const builtin = @import("builtin");

/// Source of data for reading/writing
const IoSource = union(enum) {
    file: std.fs.File,
    stream: std.net.Stream,
};

/// Generic transport interface for MCP communication
/// Adapted for Zig 0.15 IO system
pub const Transport = struct {
    read_source: IoSource,
    write_source: IoSource,
    mutex: std.Thread.Mutex = .{},

    /// Initialize transport from file handles (for stdio)
    pub fn initFromFiles(read_file: std.fs.File, write_file: std.fs.File) Transport {
        return .{
            .read_source = .{ .file = read_file },
            .write_source = .{ .file = write_file },
        };
    }

    /// Initialize transport from network stream (for TCP)
    pub fn initFromStream(stream: std.net.Stream) Transport {
        return .{
            .read_source = .{ .stream = stream },
            .write_source = .{ .stream = stream },
        };
    }

    /// Write a complete JSON-RPC message with proper formatting
    pub fn writeMessage(self: *Transport, message: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.log.debug("Transport: Writing message: {s}", .{message});

        switch (self.write_source) {
            .file => |f| {
                _ = try f.write(message);
                _ = try f.write("\n");
            },
            .stream => |s| {
                _ = try s.write(message);
                _ = try s.write("\n");
            },
        }

        std.log.debug("Transport: Message written successfully", .{});
    }

    /// Read a complete JSON-RPC message (line-based)
    pub fn readMessage(self: *Transport, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        std.log.debug("Transport: Starting to read message", .{});

        // Read byte by byte until newline
        var read_buf: [1]u8 = undefined;
        while (true) {
            const bytes_read = switch (self.read_source) {
                .file => |f| f.read(&read_buf) catch |err| {
                    std.log.debug("Transport: Read error: {any}", .{err});
                    if (buffer.items.len > 0) break;
                    return error.EndOfStream;
                },
                .stream => |s| s.read(&read_buf) catch |err| {
                    std.log.debug("Transport: Read error: {any}", .{err});
                    if (buffer.items.len > 0) break;
                    return error.EndOfStream;
                },
            };

            if (bytes_read == 0) {
                std.log.debug("Transport: EndOfStream reached, buffer length: {d}", .{buffer.items.len});
                if (buffer.items.len > 0) break;
                return error.EndOfStream;
            }

            const byte = read_buf[0];
            if (byte == '\n') {
                break;
            } else if (byte != '\r') {
                try buffer.append(allocator, byte);
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
        _ = self; // Transport doesn't own the files, so nothing to cleanup
    }
};

/// Stdio transport implementation with Windows pipe handling
pub const StdioTransport = struct {
    transport: Transport,

    pub fn init() StdioTransport {
        return StdioTransport{
            .transport = Transport.initFromFiles(std.fs.File.stdin(), std.fs.File.stdout()),
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
                error.EndOfStream => {
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
            .transport = Transport.initFromStream(stream),
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
