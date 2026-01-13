//! Logging interface for MCP server
//!
//! Provides a flexible logging mechanism with multiple implementations:
//! - NopLogger: No-op logger (default)
//! - StderrLogger: Logs to stderr
//! - FileLogger: Logs to a file
//!
//! Custom loggers can be created by implementing the Logger interface.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Logger interface
pub const Logger = struct {
    impl_ptr: *anyopaque,
    start_fn: *const fn (impl_ptr: *anyopaque, message: []const u8) void,
    log_fn: *const fn (impl_ptr: *anyopaque, source: []const u8, operation: []const u8, message: []const u8) void,
    stop_fn: *const fn (impl_ptr: *anyopaque, message: []const u8) void,

    /// Create a logger interface from an implementing object
    pub fn from(impl_obj: anytype) Logger {
        const ImplType = @TypeOf(impl_obj);

        const Delegate = struct {
            fn start(impl_ptr: *anyopaque, message: []const u8) void {
                const impl: ImplType = @ptrCast(@alignCast(impl_ptr));
                impl.start(message);
            }

            fn log(impl_ptr: *anyopaque, source: []const u8, operation: []const u8, message: []const u8) void {
                const impl: ImplType = @ptrCast(@alignCast(impl_ptr));
                impl.log(source, operation, message);
            }

            fn stop(impl_ptr: *anyopaque, message: []const u8) void {
                const impl: ImplType = @ptrCast(@alignCast(impl_ptr));
                impl.stop(message);
            }
        };

        return .{
            .impl_ptr = impl_obj,
            .start_fn = Delegate.start,
            .log_fn = Delegate.log,
            .stop_fn = Delegate.stop,
        };
    }

    pub fn start(self: Logger, message: []const u8) void {
        self.start_fn(self.impl_ptr, message);
    }

    pub fn log(self: Logger, source: []const u8, operation: []const u8, message: []const u8) void {
        self.log_fn(self.impl_ptr, source, operation, message);
    }

    pub fn stop(self: Logger, message: []const u8) void {
        self.stop_fn(self.impl_ptr, message);
    }
};

/// No-op logger (default)
pub const NopLogger = struct {
    pub fn start(_: *NopLogger, _: []const u8) void {}
    pub fn log(_: *NopLogger, _: []const u8, _: []const u8, _: []const u8) void {}
    pub fn stop(_: *NopLogger, _: []const u8) void {}

    pub fn asLogger(self: *NopLogger) Logger {
        return Logger.from(self);
    }
};

/// Default no-op logger instance
pub var nop_logger = NopLogger{};

/// Logger that writes to stderr using std.log
pub const StderrLogger = struct {
    prefix: []const u8 = "",

    pub fn start(self: *StderrLogger, message: []const u8) void {
        _ = self;
        std.log.info("[START] {s}", .{message});
    }

    pub fn log(self: *StderrLogger, source: []const u8, operation: []const u8, message: []const u8) void {
        if (self.prefix.len > 0) {
            std.log.info("[{s}] [{s}] {s}: {s}", .{ self.prefix, source, operation, message });
        } else {
            std.log.info("[{s}] {s}: {s}", .{ source, operation, message });
        }
    }

    pub fn stop(self: *StderrLogger, message: []const u8) void {
        _ = self;
        std.log.info("[STOP] {s}", .{message});
    }

    pub fn asLogger(self: *StderrLogger) Logger {
        return Logger.from(self);
    }
};

/// Logger that writes to a file
pub const FileLogger = struct {
    allocator: Allocator,
    file: std.fs.File,
    prefix: []const u8 = "",

    pub fn init(allocator: Allocator, path: []const u8) !FileLogger {
        const file = try std.fs.cwd().createFile(path, .{});
        return .{
            .allocator = allocator,
            .file = file,
        };
    }

    pub fn deinit(self: *FileLogger) void {
        self.file.close();
    }

    pub fn start(self: *FileLogger, message: []const u8) void {
        self.writeLog("START", message);
    }

    pub fn log(self: *FileLogger, source: []const u8, operation: []const u8, message: []const u8) void {
        const writer = self.file.writer();
        const timestamp = std.time.timestamp();
        if (self.prefix.len > 0) {
            writer.print("[{d}] [{s}] ", .{ timestamp, self.prefix }) catch {};
        } else {
            writer.print("[{d}] ", .{timestamp}) catch {};
        }
        writer.print("[{s}] {s}: {s}\n", .{ source, operation, message }) catch {};
    }

    pub fn stop(self: *FileLogger, message: []const u8) void {
        self.writeLog("STOP", message);
    }

    fn writeLog(self: *FileLogger, level: []const u8, message: []const u8) void {
        const writer = self.file.writer();
        const timestamp = std.time.timestamp();
        if (self.prefix.len > 0) {
            writer.print("[{d}] [{s}] ", .{ timestamp, self.prefix }) catch {};
        } else {
            writer.print("[{d}] ", .{timestamp}) catch {};
        }
        writer.print("[{s}] {s}\n", .{ level, message }) catch {};
    }

    pub fn asLogger(self: *FileLogger) Logger {
        return Logger.from(self);
    }
};

// ==================== Tests ====================

test "NopLogger does nothing" {
    var logger = NopLogger{};
    const l = logger.asLogger();
    l.start("test");
    l.log("source", "op", "message");
    l.stop("test");
}

test "StderrLogger creates interface" {
    var logger = StderrLogger{ .prefix = "test" };
    _ = logger.asLogger();
}
