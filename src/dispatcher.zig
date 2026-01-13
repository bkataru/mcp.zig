//! Dispatcher interface for JSON-RPC method routing
//!
//! Provides a flexible dispatcher pattern that routes JSON-RPC requests
//! to handler functions. Supports:
//! - Method registration by name
//! - Pre/post request hooks
//! - Error handling hooks
//! - Fallback handler for unknown methods
//! - Per-request arena allocator

const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonrpc = @import("jsonrpc.zig");

/// Result from dispatching a request
pub const DispatchResult = union(enum) {
    /// No result (for notifications)
    none: void,
    /// End the streaming session
    end_stream: void,
    /// Success result as JSON string
    result: []const u8,
    /// Error result
    err: struct {
        code: i32,
        message: []const u8,
        data: ?[]const u8 = null,
    },

    pub fn asNone() DispatchResult {
        return .{ .none = {} };
    }

    pub fn asEndStream() DispatchResult {
        return .{ .end_stream = {} };
    }

    pub fn withResult(json: []const u8) DispatchResult {
        return .{ .result = json };
    }

    pub fn withError(code: i32, message: []const u8) DispatchResult {
        return .{ .err = .{ .code = code, .message = message } };
    }

    pub fn withErrorData(code: i32, message: []const u8, data: []const u8) DispatchResult {
        return .{ .err = .{ .code = code, .message = message, .data = data } };
    }
};

/// Context passed to handlers during dispatch
pub const DispatchContext = struct {
    allocator: Allocator,
    request: *const jsonrpc.Request,
    user_data: ?*anyopaque = null,
};

/// Handler function signature
pub const HandlerFn = *const fn (ctx: *const DispatchContext, params: ?std.json.Value) anyerror!DispatchResult;

/// Hook function signatures
pub const BeforeHookFn = *const fn (ctx: *const DispatchContext) anyerror!void;
pub const AfterHookFn = *const fn (ctx: *const DispatchContext, result: DispatchResult) void;
pub const ErrorHookFn = *const fn (ctx: *const DispatchContext, err: anyerror) DispatchResult;
pub const FallbackHookFn = *const fn (ctx: *const DispatchContext) anyerror!DispatchResult;

/// Dispatcher interface - can be implemented by custom dispatchers
pub const RequestDispatcher = struct {
    impl_ptr: *anyopaque,
    dispatch_fn: *const fn (impl_ptr: *anyopaque, ctx: *const DispatchContext) anyerror!DispatchResult,
    dispatch_end_fn: *const fn (impl_ptr: *anyopaque, ctx: *const DispatchContext) void,

    /// Create a dispatcher interface from an implementing object
    pub fn from(impl_obj: anytype) RequestDispatcher {
        const ImplType = @TypeOf(impl_obj);
        if (@typeInfo(ImplType) != .pointer)
            @compileError("impl_obj should be a pointer, but its type is " ++ @typeName(ImplType));

        const Delegate = struct {
            fn dispatch(impl_ptr: *anyopaque, ctx: *const DispatchContext) anyerror!DispatchResult {
                const impl: ImplType = @ptrCast(@alignCast(impl_ptr));
                return impl.dispatch(ctx);
            }

            fn dispatchEnd(impl_ptr: *anyopaque, ctx: *const DispatchContext) void {
                const impl: ImplType = @ptrCast(@alignCast(impl_ptr));
                return impl.dispatchEnd(ctx);
            }
        };

        return .{
            .impl_ptr = impl_obj,
            .dispatch_fn = Delegate.dispatch,
            .dispatch_end_fn = Delegate.dispatchEnd,
        };
    }

    pub fn dispatch(self: RequestDispatcher, ctx: *const DispatchContext) anyerror!DispatchResult {
        return self.dispatch_fn(self.impl_ptr, ctx);
    }

    pub fn dispatchEnd(self: RequestDispatcher, ctx: *const DispatchContext) void {
        return self.dispatch_end_fn(self.impl_ptr, ctx);
    }
};

/// Method registry - maps method names to handlers
pub const MethodRegistry = struct {
    allocator: Allocator,
    handlers: std.StringHashMap(HandlerFn),
    before_hook: ?BeforeHookFn = null,
    after_hook: ?AfterHookFn = null,
    error_hook: ?ErrorHookFn = null,
    fallback_hook: ?FallbackHookFn = null,

    pub fn init(allocator: Allocator) MethodRegistry {
        return .{
            .allocator = allocator,
            .handlers = std.StringHashMap(HandlerFn).init(allocator),
        };
    }

    pub fn deinit(self: *MethodRegistry) void {
        self.handlers.deinit();
    }

    /// Register a handler for a method
    pub fn add(self: *MethodRegistry, method: []const u8, handler: HandlerFn) !void {
        try self.handlers.put(method, handler);
    }

    /// Set the before-request hook
    pub fn setOnBefore(self: *MethodRegistry, hook: BeforeHookFn) void {
        self.before_hook = hook;
    }

    /// Set the after-request hook
    pub fn setOnAfter(self: *MethodRegistry, hook: AfterHookFn) void {
        self.after_hook = hook;
    }

    /// Set the error hook
    pub fn setOnError(self: *MethodRegistry, hook: ErrorHookFn) void {
        self.error_hook = hook;
    }

    /// Set the fallback hook for unknown methods
    pub fn setOnFallback(self: *MethodRegistry, hook: FallbackHookFn) void {
        self.fallback_hook = hook;
    }

    /// Dispatch a request to the appropriate handler
    pub fn dispatch(self: *MethodRegistry, ctx: *const DispatchContext) anyerror!DispatchResult {
        // Call before hook
        if (self.before_hook) |hook| {
            try hook(ctx);
        }

        const result = blk: {
            // Look up handler
            if (self.handlers.get(ctx.request.method)) |handler| {
                break :blk handler(ctx, ctx.request.params) catch |err| {
                    // Call error hook if present
                    if (self.error_hook) |hook| {
                        break :blk hook(ctx, err);
                    }
                    return err;
                };
            } else {
                // Call fallback hook if present
                if (self.fallback_hook) |hook| {
                    break :blk try hook(ctx);
                }
                break :blk DispatchResult.withError(
                    jsonrpc.ErrorCode.MethodNotFound,
                    "Method not found",
                );
            }
        };

        // Call after hook
        if (self.after_hook) |hook| {
            hook(ctx, result);
        }

        return result;
    }

    /// Called after dispatch completes (for cleanup)
    pub fn dispatchEnd(self: *MethodRegistry, ctx: *const DispatchContext) void {
        _ = self;
        _ = ctx;
        // Per-request cleanup can be done here
    }

    /// Get as a dispatcher interface
    pub fn asDispatcher(self: *MethodRegistry) RequestDispatcher {
        return RequestDispatcher.from(self);
    }
};

// ==================== Tests ====================

fn testHandler(ctx: *const DispatchContext, params: ?std.json.Value) anyerror!DispatchResult {
    _ = params;
    _ = ctx;
    return DispatchResult.withResult("{\"hello\":\"world\"}");
}

fn testErrorHandler(_: *const DispatchContext, _: ?std.json.Value) anyerror!DispatchResult {
    return error.TestError;
}

test "MethodRegistry dispatches to handler" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    try registry.add("test", testHandler);

    const request = jsonrpc.Request{ .method = "test" };
    const ctx = DispatchContext{
        .allocator = allocator,
        .request = &request,
    };

    const result = try registry.dispatch(&ctx);
    try std.testing.expectEqual(DispatchResult{ .result = "{\"hello\":\"world\"}" }, result);
}

test "MethodRegistry returns error for unknown method" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    const request = jsonrpc.Request{ .method = "unknown" };
    const ctx = DispatchContext{
        .allocator = allocator,
        .request = &request,
    };

    const result = try registry.dispatch(&ctx);
    try std.testing.expect(result == .err);
    try std.testing.expectEqual(jsonrpc.ErrorCode.MethodNotFound, result.err.code);
}

var before_hook_called = false;
var after_hook_called = false;
var error_hook_called = false;
var fallback_hook_called = false;

fn beforeHook(ctx: *const DispatchContext) anyerror!void {
    _ = ctx;
    before_hook_called = true;
}

fn afterHook(ctx: *const DispatchContext, result: DispatchResult) void {
    _ = ctx;
    _ = result;
    after_hook_called = true;
}

fn errorHook(_: *const DispatchContext, err: anyerror) DispatchResult {
    _ = err catch {};
    error_hook_called = true;
    return DispatchResult.withError(-1, "Error hook called");
}

fn fallbackHook(ctx: *const DispatchContext) anyerror!DispatchResult {
    _ = ctx;
    fallback_hook_called = true;
    return DispatchResult.withResult("fallback");
}

fn countingHandler(_: *const DispatchContext, _: ?std.json.Value) anyerror!DispatchResult {
    return DispatchResult.withResult("counted");
}

test "MethodRegistry onBefore hook" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    before_hook_called = false;
    try registry.add("count", countingHandler);
    registry.setOnBefore(beforeHook);

    const request = jsonrpc.Request{ .method = "count" };
    const ctx = DispatchContext{
        .allocator = allocator,
        .request = &request,
    };

    _ = try registry.dispatch(&ctx);
    try std.testing.expect(before_hook_called);
}

test "MethodRegistry onAfter hook" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    after_hook_called = false;
    try registry.add("count", countingHandler);
    registry.setOnAfter(afterHook);

    const request = jsonrpc.Request{ .method = "count" };
    const ctx = DispatchContext{
        .allocator = allocator,
        .request = &request,
    };

    _ = try registry.dispatch(&ctx);
    try std.testing.expect(after_hook_called);
}

test "MethodRegistry onError hook" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    error_hook_called = false;
    try registry.add("error", testErrorHandler);
    registry.setOnError(errorHook);

    const request = jsonrpc.Request{ .method = "error" };
    const ctx = DispatchContext{
        .allocator = allocator,
        .request = &request,
    };

    _ = registry.dispatch(&ctx) catch {};
    try std.testing.expect(error_hook_called);
}

test "MethodRegistry onFallback hook" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    fallback_hook_called = false;
    registry.setOnFallback(fallbackHook);

    const request = jsonrpc.Request{ .method = "nonexistent" };
    const ctx = DispatchContext{
        .allocator = allocator,
        .request = &request,
    };

    const result = try registry.dispatch(&ctx);
    try std.testing.expect(fallback_hook_called);
    try std.testing.expectEqualStrings("fallback", result.result);
}

test "DispatchContext with id" {
    const allocator = std.testing.allocator;
    const request = jsonrpc.Request{
        .method = "test",
        .id = jsonrpc.RequestId{ .integer = 42 },
    };
    const ctx = DispatchContext{
        .allocator = allocator,
        .request = &request,
    };

    try std.testing.expect(ctx.request.id != null);
    try std.testing.expectEqual(@as(i64, 42), ctx.request.id.?.integer);
}

test "DispatchContext with string id" {
    const allocator = std.testing.allocator;
    const request = jsonrpc.Request{
        .method = "test",
        .id = jsonrpc.RequestId{ .string = "test-id" },
    };
    const ctx = DispatchContext{
        .allocator = allocator,
        .request = &request,
    };

    try std.testing.expectEqualStrings("test-id", ctx.request.id.?.string);
}

test "DispatchContext without id (notification)" {
    const allocator = std.testing.allocator;
    const request = jsonrpc.Request{
        .method = "notify",
        .id = null,
    };
    const ctx = DispatchContext{
        .allocator = allocator,
        .request = &request,
    };

    try std.testing.expect(ctx.request.id == null);
}

test "DispatchResult with error and data" {
    const result = DispatchResult{
        .err = .{
            .code = -32600,
            .message = "Invalid request",
            .data = "extra info",
        },
    };

    try std.testing.expectEqual(@as(i32, -32600), result.err.code);
    try std.testing.expectEqualStrings("Invalid request", result.err.message);
    try std.testing.expectEqualStrings("extra info", result.err.data.?);
}

test "DispatchResult null result" {
    const result = DispatchResult{ .none = {} };
    try std.testing.expect(result == .none);
}
