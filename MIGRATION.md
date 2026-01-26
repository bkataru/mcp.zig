# Migration Guide: std.io to std.Io (Zig 0.15.x)

This guide documents the migration from the deprecated `std.io` APIs to the new `std.Io` APIs in Zig 0.15.x. These changes affect how you work with readers, writers, fixed buffer streams, and JSON serialization.

## Overview

Zig 0.15.x introduces a new I/O subsystem under `std.Io` that replaces the older `std.io` patterns. The new API provides:

- **Polymorphic interfaces** via vtables instead of generic type parameters
- **Explicit buffer management** requiring heap-allocated buffers for file I/O
- **Unified Reader/Writer types** that work across files, network streams, and memory buffers
- **New JSON serialization** via `std.json.Stringify`

## Key Changes

### 1. Standard I/O (stdin/stdout/stderr)

The functions for getting standard I/O handles have moved from `std.io` to `std.fs.File`.

#### Before (Deprecated)
```zig
const std = @import("std");

// Getting standard I/O handles
const stdin = std.io.getStdIn();
const stdout = std.io.getStdOut();
const stderr = std.io.getStdErr();

// Getting readers/writers directly
const reader = stdin.reader();
const writer = stdout.writer();
```

#### After (Zig 0.15.x)
```zig
const std = @import("std");

// Getting standard I/O handles
const stdin_file = std.fs.File.stdin();
const stdout_file = std.fs.File.stdout();
const stderr_file = std.fs.File.stderr();

// Getting readers/writers requires a buffer
var read_buffer: [8192]u8 = undefined;
var write_buffer: [8192]u8 = undefined;

var file_reader = stdin_file.reader(&read_buffer);
var file_writer = stdout_file.writer(&write_buffer);

// Access the polymorphic interface
const reader: *std.Io.Reader = &file_reader.interface;
const writer: *std.Io.Writer = &file_writer.interface;
```

**Key Difference**: File readers/writers now require explicit buffer allocation. The buffer is used internally for buffering I/O operations.

### 2. Reader/Writer Interfaces

The polymorphic reader/writer interfaces have changed from `std.io.AnyReader`/`std.io.AnyWriter` to `std.Io.Reader`/`std.Io.Writer`.

#### Before (Deprecated)
```zig
const std = @import("std");

fn processData(reader: std.io.AnyReader, writer: std.io.AnyWriter) !void {
    const data = try reader.readAllAlloc(allocator, max_size);
    try writer.writeAll(data);
}

// Creating from a file
const file = try std.fs.cwd().openFile("data.txt", .{});
const reader = file.reader().any();
```

#### After (Zig 0.15.x)
```zig
const std = @import("std");

fn processData(reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    const data = reader.take(max_size) catch |err| {
        return if (err == error.ReadFailed) error.EndOfStream else err;
    };
    try writer.writeAll(data);
    try writer.flush();
}

// Creating from a file with buffer
const file = try std.fs.cwd().openFile("data.txt", .{});
var buffer: [8192]u8 = undefined;
var file_reader = file.reader(&buffer);
const reader: *std.Io.Reader = &file_reader.interface;
```

**Key Differences**:
- Use pointer types (`*std.Io.Reader`) instead of value types
- Access via `.interface` field on file/stream readers
- Call `.flush()` on writers to ensure data is written
- Use `.take()` to read buffered data

### 3. Fixed Buffer Streams

Fixed buffer streams for in-memory I/O have been replaced with static methods on `Reader` and `Writer`.

#### Before (Deprecated)
```zig
const std = @import("std");

// Reading from a fixed buffer
const input = "Hello, World!";
var stream = std.io.fixedBufferStream(input);
const reader = stream.reader();

// Writing to a fixed buffer
var output: [256]u8 = undefined;
var write_stream = std.io.fixedBufferStream(&output);
const writer = write_stream.writer();
try writer.writeAll("test");
const written = write_stream.getWritten();
```

#### After (Zig 0.15.x)
```zig
const std = @import("std");

// Reading from a fixed buffer
const input = "Hello, World!";
var reader = std.Io.Reader.fixed(input);
// reader is already a std.Io.Reader - no need for .interface

// Writing to a fixed buffer
var output: [256]u8 = undefined;
var writer = std.Io.Writer.fixed(&output);
try writer.writeAll("test");
const written = writer.buffered();  // Get what was written
```

**Key Differences**:
- Use `std.Io.Reader.fixed()` / `std.Io.Writer.fixed()` static methods
- For writers, use `.buffered()` to get the written slice
- The fixed reader/writer are already the interface type, no `.interface` access needed

### 4. JSON Serialization

JSON serialization has moved from `std.json.stringify` to `std.json.Stringify`.

#### Before (Deprecated)
```zig
const std = @import("std");

// Stringify to a writer
var buffer: [1024]u8 = undefined;
var stream = std.io.fixedBufferStream(&buffer);
try std.json.stringify(my_value, .{}, stream.writer());
const json_output = stream.getWritten();

// Stringify with allocation
const json_string = try std.json.stringifyAlloc(allocator, my_value, .{});
defer allocator.free(json_string);
```

#### After (Zig 0.15.x)
```zig
const std = @import("std");

// Stringify to a fixed buffer
var buffer: [1024]u8 = undefined;
var writer = std.Io.Writer.fixed(&buffer);
try std.json.Stringify.value(my_value, .{}, &writer);
const json_output = writer.buffered();

// Stringify with allocation using Allocating writer
var out: std.io.Writer.Allocating = .init(allocator);
defer out.deinit();
try std.json.Stringify.value(my_value, .{}, &out.writer);
const json_string = out.written();  // Returns []const u8
```

**Key Differences**:
- Use `std.json.Stringify.value()` instead of `std.json.stringify()`
- For allocated output, use `std.io.Writer.Allocating`
- Call `.written()` on `Allocating` to get the result
- Remember to `.deinit()` the `Allocating` writer

### 5. Network Stream Readers/Writers

Network streams also require explicit buffer management.

#### Before (Deprecated)
```zig
const std = @import("std");

const stream = try server.accept();
const reader = stream.reader();
const writer = stream.writer();

// Read data
var buf: [1024]u8 = undefined;
const n = try reader.read(&buf);
```

#### After (Zig 0.15.x)
```zig
const std = @import("std");

const stream = try server.accept();

// Allocate buffers for the stream
var read_buffer: [8192]u8 = undefined;
var write_buffer: [8192]u8 = undefined;

var stream_reader = stream.reader(&read_buffer);
var stream_writer = stream.writer(&write_buffer);

// Access the polymorphic interface
const reader: *std.Io.Reader = stream_reader.interface();
const writer: *std.Io.Writer = &stream_writer.interface;

// Read data
const data = try reader.take(1024);
```

## Common Patterns

### Pattern 1: Wrapping File I/O with Buffers

When working with files, always allocate buffers:

```zig
const BUFFER_SIZE: usize = 8192;

pub const BufferedFile = struct {
    file: std.fs.File,
    read_buffer: *[BUFFER_SIZE]u8,
    write_buffer: *[BUFFER_SIZE]u8,
    file_reader: ?std.fs.File.Reader,
    file_writer: ?std.fs.File.Writer,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, file: std.fs.File) !BufferedFile {
        const read_buf = try allocator.create([BUFFER_SIZE]u8);
        errdefer allocator.destroy(read_buf);
        const write_buf = try allocator.create([BUFFER_SIZE]u8);
        errdefer allocator.destroy(write_buf);

        return .{
            .file = file,
            .read_buffer = read_buf,
            .write_buffer = write_buf,
            .file_reader = file.reader(read_buf),
            .file_writer = file.writer(write_buf),
            .allocator = allocator,
        };
    }

    pub fn reader(self: *BufferedFile) *std.Io.Reader {
        return &self.file_reader.?.interface;
    }

    pub fn writer(self: *BufferedFile) *std.Io.Writer {
        return &self.file_writer.?.interface;
    }

    pub fn deinit(self: *BufferedFile) void {
        if (self.file_writer) |*fw| {
            fw.interface.flush() catch {};
        }
        self.file.close();
        self.allocator.destroy(self.read_buffer);
        self.allocator.destroy(self.write_buffer);
    }
};
```

### Pattern 2: JSON Serialization to Allocated String

```zig
fn serializeToJson(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try std.json.Stringify.value(value, .{}, &out.writer);
    
    // Transfer ownership - caller must free
    const result = out.written();
    // Note: Don't deinit here since we're returning the buffer
    return result;
}
```

### Pattern 3: Testing with Fixed Buffers

```zig
test "write and verify output" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writer.print("Hello, {s}!", .{"World"});
    
    const output = writer.buffered();
    try std.testing.expectEqualStrings("Hello, World!", output);
}

test "read from fixed input" {
    const input = "{\"key\":\"value\"}";
    var reader = std.Io.Reader.fixed(input);

    const data = try reader.take(input.len);
    try std.testing.expectEqualStrings(input, data);
}
```

### Pattern 4: Reading Line by Line

The old `readUntilDelimiter` is replaced with manual byte-by-byte reading:

```zig
fn readLine(reader: *std.Io.Reader, buffer: []u8, delimiter: u8) !usize {
    var index: usize = 0;
    while (index < buffer.len) {
        const bytes = reader.take(1) catch |err| {
            if (err == error.ReadFailed) {
                if (index > 0) return index;
                return error.EndOfStream;
            }
            return err;
        };
        if (bytes[0] == delimiter) {
            return index;
        }
        buffer[index] = bytes[0];
        index += 1;
    }
    return error.StreamTooLong;
}
```

### Pattern 5: Formatted Printing

```zig
// To a fixed buffer
var buffer: [256]u8 = undefined;
var writer = std.Io.Writer.fixed(&buffer);
try writer.print("Count: {d}, Name: {s}", .{42, "test"});
const result = writer.buffered();

// To an allocating buffer
var out: std.io.Writer.Allocating = .init(allocator);
defer out.deinit();
try out.writer.print("Count: {d}, Name: {s}", .{42, "test"});
const result = out.written();
```

## Migration Checklist

- [ ] Replace `std.io.getStdIn()` with `std.fs.File.stdin()`
- [ ] Replace `std.io.getStdOut()` with `std.fs.File.stdout()`
- [ ] Replace `std.io.getStdErr()` with `std.fs.File.stderr()`
- [ ] Allocate buffers for file/stream readers and writers
- [ ] Replace `std.io.AnyReader` with `*std.Io.Reader`
- [ ] Replace `std.io.AnyWriter` with `*std.Io.Writer`
- [ ] Replace `std.io.fixedBufferStream()` with `std.Io.Reader.fixed()` / `std.Io.Writer.fixed()`
- [ ] Replace `.getWritten()` with `.buffered()` for fixed writers
- [ ] Replace `std.json.stringify()` with `std.json.Stringify.value()`
- [ ] Use `std.io.Writer.Allocating` for dynamically-sized JSON output
- [ ] Add `.flush()` calls before closing writers
- [ ] Update function signatures to use pointer types for readers/writers

## Error Handling Changes

The new I/O API uses simplified error types:

| Old Error | New Error | Notes |
|-----------|-----------|-------|
| Various read errors | `error.ReadFailed` | Check reader state for details |
| Various write errors | `error.WriteFailed` | Check writer state for details |
| `error.EndOfStream` | `error.ReadFailed` | Need to check context |

## References

- Source files demonstrating the new API:
  - `src/network.zig` - Network I/O with buffered readers/writers
  - `src/streaming.zig` - Fixed buffer streams and JSON framing
  - `src/progress.zig` - JSON serialization with Stringify
- Zig stdlib source: `lib/std/Io/Reader.zig`, `lib/std/Io/Writer.zig`
