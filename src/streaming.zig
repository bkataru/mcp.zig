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
const StringArrayList = std.array_list.AlignedManaged([]const u8, null);

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

/// Read a single byte from a reader (Zig 0.15.x std.Io.Reader API)
fn readSingleByte(reader: *std.Io.Reader) !u8 {
    const bytes = reader.take(1) catch |err| {
        return if (err == error.ReadFailed) error.EndOfStream else err;
    };
    return bytes[0];
}

/// Read a line from reader until delimiter (replacement for deprecated readUntilDelimiter)
/// Returns the number of bytes read (excluding delimiter), or error
fn readLineUntilDelimiter(reader: *std.Io.Reader, buffer: []u8, delimiter: u8) !usize {
    var index: usize = 0;
    while (index < buffer.len) {
        const byte = readSingleByte(reader) catch |err| {
            if (err == error.EndOfStream) {
                if (index > 0) return index;
                return err;
            }
            return err;
        };
        if (byte == delimiter) {
            return index;
        }
        buffer[index] = byte;
        index += 1;
    }
    return error.StreamTooLong;
}

/// Read a Content-Length framed message from a reader
/// Returns the message content (caller owns the memory)
pub fn readContentLengthFrame(allocator: Allocator, reader: *std.Io.Reader) FrameError![]u8 {
    var content_length: ?usize = null;
    var line_buf: [1024]u8 = undefined;

    // Read headers until empty line
    while (true) {
        const line_len = readLineUntilDelimiter(reader, &line_buf, '\n') catch |err| {
            return if (err == error.EndOfStream) FrameError.EndOfStream else FrameError.InvalidHeader;
        };
        const line = line_buf[0..line_len];

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

    // Use readSliceAll for std.Io.Reader API
    reader.readSliceAll(buffer) catch |err| {
        return if (err == error.EndOfStream) FrameError.EndOfStream else FrameError.InvalidHeader;
    };

    return buffer;
}

/// Write a Content-Length framed message to a writer
pub fn writeContentLengthFrame(writer: *std.Io.Writer, message: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{message.len});
    try writer.writeAll(message);
}

/// Read a delimiter-framed message from a reader
/// Returns the message content (caller owns the memory)
pub fn readDelimiterFrame(allocator: Allocator, reader: *std.Io.Reader, delimiter: u8) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8){};
    errdefer buffer.deinit(allocator);

    while (true) {
        const byte = readSingleByte(reader) catch |err| {
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
pub fn writeDelimiterFrame(writer: *std.Io.Writer, message: []const u8, delimiter: u8) !void {
    try writer.writeAll(message);
    try writer.writeByte(delimiter);
}

// ==================== Tests ====================

test "readContentLengthFrame parses valid message" {
    const input = "Content-Length: 13\r\n\r\n{\"test\":true}";
    var reader = std.Io.Reader.fixed(input);

    const message = try readContentLengthFrame(std.testing.allocator, &reader);
    defer std.testing.allocator.free(message);

    try std.testing.expectEqualStrings("{\"test\":true}", message);
}

test "readContentLengthFrame handles missing header" {
    const input = "\r\n{\"test\":true}";
    var reader = std.Io.Reader.fixed(input);

    const result = readContentLengthFrame(std.testing.allocator, &reader);
    try std.testing.expectError(FrameError.MissingContentLength, result);
}

test "writeContentLengthFrame produces valid output" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeContentLengthFrame(&writer, "{\"id\":1}");

    const written = writer.buffered();
    try std.testing.expectEqualStrings("Content-Length: 8\r\n\r\n{\"id\":1}", written);
}

test "readDelimiterFrame parses newline-delimited message" {
    const input = "{\"test\":true}\n{\"next\":1}";
    var reader = std.Io.Reader.fixed(input);

    const message = try readDelimiterFrame(std.testing.allocator, &reader, '\n');
    defer std.testing.allocator.free(message);

    try std.testing.expectEqualStrings("{\"test\":true}", message);
}

/// Streaming response builder for multi-part responses
pub const StreamingResponse = struct {
    allocator: std.mem.Allocator,
    chunks: StringArrayList,
    total_size: usize = 0,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return @This(){
            .allocator = allocator,
            .chunks = StringArrayList.init(allocator),
            .total_size = 0,
        };
    }

    pub fn deinit(self: *@This()) void {
        for (self.chunks.items) |chunk| {
            self.allocator.free(chunk);
        }
        self.chunks.deinit();
    }

    /// Add a chunk to the streaming response
    pub fn addChunk(self: *@This(), chunk: []const u8) !void {
        const chunk_copy = try self.allocator.dupe(u8, chunk);
        try self.chunks.append(chunk_copy);
        self.total_size += chunk.len;
    }

    /// Get total size of all chunks
    pub fn getTotalSize(self: *@This()) usize {
        return self.total_size;
    }

    /// Get chunk count
    pub fn getChunkCount(self: *@This()) usize {
        return self.chunks.items.len;
    }

    /// Combine all chunks into a single buffer
    pub fn combine(self: *@This()) ![]const u8 {
        const combined = try self.allocator.alloc(u8, self.total_size);
        var offset: usize = 0;
        for (self.chunks.items) |chunk| {
            std.mem.copyForwards(u8, combined[offset..], chunk);
            offset += chunk.len;
        }
        return combined;
    }

    /// Stream chunks to a writer
    pub fn streamTo(self: *@This(), writer: *std.Io.Writer) !void {
        for (self.chunks.items) |chunk| {
            try writer.writeAll(chunk);
        }
    }
};

/// Batched response writer for sending multiple JSON-RPC responses
pub const BatchedWriter = struct {
    allocator: std.mem.Allocator,
    responses: StringArrayList,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return @This(){
            .allocator = allocator,
            .responses = StringArrayList.init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        for (self.responses.items) |response| {
            self.allocator.free(response);
        }
        self.responses.deinit();
    }

    /// Add a response to the batch
    pub fn addResponse(self: *@This(), response_json: []const u8) !void {
        const response_copy = try self.allocator.dupe(u8, response_json);
        try self.responses.append(response_copy);
    }

    /// Get response count
    pub fn count(self: *@This()) usize {
        return self.responses.items.len;
    }

    /// Write all responses as a JSON array
    pub fn writeBatch(self: *@This(), writer: *std.Io.Writer) !void {
        try writer.writeAll("[");
        for (self.responses.items, 0..) |response, i| {
            if (i > 0) {
                try writer.writeAll(",");
            }
            try writer.writeAll(response);
        }
        try writer.writeAll("]");
    }

    /// Write all responses individually with Content-Length framing
    pub fn writeBatchFramed(self: *@This(), writer: *std.Io.Writer) !void {
        for (self.responses.items) |response| {
            try writeContentLengthFrame(writer, response);
        }
    }
};

test "StreamingResponse" {
    const allocator = std.testing.allocator;
    var streaming = StreamingResponse.init(allocator);
    defer streaming.deinit();

    try streaming.addChunk("part1");
    try streaming.addChunk("part2");
    try streaming.addChunk("part3");

    try std.testing.expectEqual(@as(usize, 3), streaming.getChunkCount());
    try std.testing.expectEqual(@as(usize, 15), streaming.getTotalSize());

    const combined = try streaming.combine();
    defer allocator.free(combined);
    try std.testing.expectEqualStrings("part1part2part3", combined);
}

test "BatchedWriter" {
    const allocator = std.testing.allocator;
    var batch = BatchedWriter.init(allocator);
    defer batch.deinit();

    try batch.addResponse("{\"id\":1,\"result\":\"ok\"}");
    try batch.addResponse("{\"id\":2,\"result\":\"done\"}");

    try std.testing.expectEqual(@as(usize, 2), batch.count());
}

// ==================== Edge Case Tests ====================

test "readSingleByte with empty buffer returns EndOfStream" {
    var reader = std.Io.Reader.fixed("");

    const result = readSingleByte(&reader);
    try std.testing.expectError(error.EndOfStream, result);
}

test "readLineUntilDelimiter with buffer overflow returns StreamTooLong" {
    const input = "this is a very long line without delimiter";
    var reader = std.Io.Reader.fixed(input);

    var small_buffer: [5]u8 = undefined;
    const result = readLineUntilDelimiter(&reader, &small_buffer, '\n');
    try std.testing.expectError(error.StreamTooLong, result);
}

test "readContentLengthFrame with invalid content-length returns InvalidContentLength" {
    const input = "Content-Length: not-a-number\r\n\r\n{\"test\":true}";
    var reader = std.Io.Reader.fixed(input);

    const result = readContentLengthFrame(std.testing.allocator, &reader);
    try std.testing.expectError(FrameError.InvalidContentLength, result);
}

test "readContentLengthFrame with negative content-length returns InvalidContentLength" {
    const input = "Content-Length: -5\r\n\r\n{\"test\":true}";
    var reader = std.Io.Reader.fixed(input);

    const result = readContentLengthFrame(std.testing.allocator, &reader);
    try std.testing.expectError(FrameError.InvalidContentLength, result);
}

test "writeBatch with empty batch writes empty array" {
    const allocator = std.testing.allocator;
    var batch = BatchedWriter.init(allocator);
    defer batch.deinit();

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try batch.writeBatch(&writer);

    const written = writer.buffered();
    try std.testing.expectEqualStrings("[]", written);
}

test "StreamingResponse.streamTo writes all chunks to writer" {
    const allocator = std.testing.allocator;
    var streaming = StreamingResponse.init(allocator);
    defer streaming.deinit();

    try streaming.addChunk("hello");
    try streaming.addChunk(" ");
    try streaming.addChunk("world");

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try streaming.streamTo(&writer);

    const written = writer.buffered();
    try std.testing.expectEqualStrings("hello world", written);
}

test "StreamingResponse.streamTo with empty chunks" {
    const allocator = std.testing.allocator;
    var streaming = StreamingResponse.init(allocator);
    defer streaming.deinit();

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try streaming.streamTo(&writer);

    const written = writer.buffered();
    try std.testing.expectEqualStrings("", written);
}

test "writeDelimiterFrame with empty message writes only delimiter" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeDelimiterFrame(&writer, "", '\n');

    const written = writer.buffered();
    try std.testing.expectEqualStrings("\n", written);
}

test "writeDelimiterFrame with custom delimiter" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeDelimiterFrame(&writer, "test", 0);

    const written = writer.buffered();
    try std.testing.expectEqual(@as(usize, 5), written.len);
    try std.testing.expectEqualStrings("test", written[0..4]);
    try std.testing.expectEqual(@as(u8, 0), written[4]);
}

test "readContentLengthFrame with message too large returns MessageTooLarge" {
    // Construct a header with content-length exceeding MAX_MESSAGE_SIZE
    const input = "Content-Length: 17000000\r\n\r\n";
    var reader = std.Io.Reader.fixed(input);

    const result = readContentLengthFrame(std.testing.allocator, &reader);
    try std.testing.expectError(FrameError.MessageTooLarge, result);
}

test "readContentLengthFrame with truncated body returns EndOfStream" {
    // Header says 20 bytes but only 5 are provided
    const input = "Content-Length: 20\r\n\r\nhello";
    var reader = std.Io.Reader.fixed(input);

    const result = readContentLengthFrame(std.testing.allocator, &reader);
    try std.testing.expectError(FrameError.EndOfStream, result);
}

test "readDelimiterFrame with empty input returns EndOfStream" {
    var reader = std.Io.Reader.fixed("");

    const result = readDelimiterFrame(std.testing.allocator, &reader, '\n');
    try std.testing.expectError(error.EndOfStream, result);
}

test "readLineUntilDelimiter with empty input returns EndOfStream" {
    var reader = std.Io.Reader.fixed("");

    var buffer: [10]u8 = undefined;
    const result = readLineUntilDelimiter(&reader, &buffer, '\n');
    try std.testing.expectError(error.EndOfStream, result);
}

test "readLineUntilDelimiter returns partial content without delimiter at EOF" {
    const input = "partial";
    var reader = std.Io.Reader.fixed(input);

    var buffer: [20]u8 = undefined;
    const len = try readLineUntilDelimiter(&reader, &buffer, '\n');

    try std.testing.expectEqual(@as(usize, 7), len);
    try std.testing.expectEqualStrings("partial", buffer[0..len]);
}
