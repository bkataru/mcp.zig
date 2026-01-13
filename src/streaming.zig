//! Streaming layer for JSON-RPC message framing
//!
//! Supports both delimiter-based streaming (newline) and Content-Length based
//! streaming (LSP/MCP style). Content-Length streaming uses HTTP-like headers:
//!
//! Content-Length: 42\r\n
//! \r\n
//! {"jsonrpc":"2.0","method":"test","id":1}
//!

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Options for delimiter-based streaming
pub const DelimiterOptions = struct {
    request_delimiter: u8 = '\n',
    response_delimiter: u8 = '\n',
    skip_blank: bool = true,
};

/// Options for Content-Length based streaming
pub const ContentLengthOptions = struct {
    skip_blank: bool = true,
    recover_on_error: bool = true,
};

/// Frame reading errors
pub const FrameError = error{
    EndOfStream,
    InvalidContentLength,
    MissingContentLength,
    InvalidHeader,
    MessageTooLarge,
    OutOfMemory,
};

/// Maximum message size (16MB)
pub const MAX_MESSAGE_SIZE: usize = 16 * 1024 * 1024;

/// Read a Content-Length framed message from a reader
/// Returns the message content (caller owns the memory)
pub fn readContentLengthFrame(allocator: Allocator, reader: anytype) FrameError![]u8 {
    var content_length: ?usize = null;
    var line_buf: [1024]u8 = undefined;

    // Read headers until empty line
    while (true) {
        const line = reader.readUntilDelimiter(&line_buf, '\n') catch |err| {
            return if (err == error.EndOfStream) FrameError.EndOfStream else FrameError.InvalidHeader;
        };

        // Strip \r if present
        const trimmed = std.mem.trimRight(u8, line, "\r");

        // Empty line marks end of headers
        if (trimmed.len == 0) break;

        // Parse Content-Length header
        if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
            const value_str = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, value_str, 10) catch {
                return FrameError.InvalidContentLength;
            };
        }
        // Ignore other headers
    }

    const length = content_length orelse return FrameError.MissingContentLength;

    if (length > MAX_MESSAGE_SIZE) {
        return FrameError.MessageTooLarge;
    }

    // Read the message body
    const buffer = allocator.alloc(u8, length) catch return FrameError.OutOfMemory;
    errdefer allocator.free(buffer);

    const bytes_read = reader.readAll(buffer) catch |err| {
        allocator.free(buffer);
        return if (err == error.EndOfStream) FrameError.EndOfStream else FrameError.InvalidHeader;
    };

    if (bytes_read != length) {
        allocator.free(buffer);
        return FrameError.EndOfStream;
    }

    return buffer;
}

/// Write a Content-Length framed message to a writer
pub fn writeContentLengthFrame(writer: anytype, message: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{message.len});
    try writer.writeAll(message);
}

/// Read a delimiter-framed message from a reader
/// Returns the message content (caller owns the memory)
pub fn readDelimiterFrame(allocator: Allocator, reader: anytype, delimiter: u8) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8){};
    errdefer buffer.deinit(allocator);

    while (true) {
        const byte = reader.readByte() catch |err| {
            if (err == error.EndOfStream) {
                if (buffer.items.len > 0) {
                    return buffer.toOwnedSlice(allocator);
                }
                return err;
            }
            return err;
        };

        if (byte == delimiter) {
            break;
        }

        try buffer.append(allocator, byte);

        if (buffer.items.len > MAX_MESSAGE_SIZE) {
            return FrameError.MessageTooLarge;
        }
    }

    return buffer.toOwnedSlice(allocator);
}

/// Write a delimiter-framed message to a writer
pub fn writeDelimiterFrame(writer: anytype, message: []const u8, delimiter: u8) !void {
    try writer.writeAll(message);
    try writer.writeByte(delimiter);
}

// ==================== Tests ====================

test "readContentLengthFrame parses valid message" {
    const input = "Content-Length: 13\r\n\r\n{\"test\":true}";
    var stream = std.io.fixedBufferStream(input);
    const reader = stream.reader();

    const message = try readContentLengthFrame(std.testing.allocator, reader);
    defer std.testing.allocator.free(message);

    try std.testing.expectEqualStrings("{\"test\":true}", message);
}

test "readContentLengthFrame handles missing header" {
    const input = "\r\n{\"test\":true}";
    var stream = std.io.fixedBufferStream(input);
    const reader = stream.reader();

    const result = readContentLengthFrame(std.testing.allocator, reader);
    try std.testing.expectError(FrameError.MissingContentLength, result);
}

test "writeContentLengthFrame produces valid output" {
    var buffer: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    try writeContentLengthFrame(writer, "{\"id\":1}");

    const written = stream.getWritten();
    try std.testing.expectEqualStrings("Content-Length: 8\r\n\r\n{\"id\":1}", written);
}

test "readDelimiterFrame parses newline-delimited message" {
    const input = "{\"test\":true}\n{\"next\":1}";
    var stream = std.io.fixedBufferStream(input);
    const reader = stream.reader();

    const message = try readDelimiterFrame(std.testing.allocator, reader, '\n');
    defer std.testing.allocator.free(message);

    try std.testing.expectEqualStrings("{\"test\":true}", message);
}
