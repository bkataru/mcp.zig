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
pub const HandlerFn = *const fn (ctx: *DispatchContext, params: ?std.json.Value) anyerror!DispatchResult;

/// Hook function signatures
pub const BeforeHookFn = *const fn (ctx: *DispatchContext) anyerror!void;
pub const AfterHookFn = *const fn (ctx: *DispatchContext, result: DispatchResult) void;
pub const ErrorHookFn = *const fn (ctx: *DispatchContext, err: anyerror) DispatchResult;
pub const FallbackHookFn = *const fn (ctx: *DispatchContext) anyerror!DispatchResult;

/// Dispatcher interface - can be implemented by custom dispatchers
pub const RequestDispatcher = struct {
    impl_ptr: *anyopaque,
    dispatch_fn: *const fn (impl_ptr: *anyopaque, ctx: *DispatchContext) anyerror!DispatchResult,
    dispatch_end_fn: *const fn (impl_ptr: *anyopaque, ctx: *DispatchContext) void,

    /// Create a dispatcher interface from an implementing object
    pub fn from(impl_obj: anytype) RequestDispatcher {
        const ImplType = @TypeOf(impl_obj);
        if (@typeInfo(ImplType) != .pointer)
            @compileError("impl_obj should be a pointer, but its type is " ++ @typeName(ImplType));

        const Delegate = struct {
            fn dispatch(impl_ptr: *anyopaque, ctx: *DispatchContext) anyerror!DispatchResult {
                const impl: ImplType = @ptrCast(@alignCast(impl_ptr));
                return impl.dispatch(ctx);
            }

            fn dispatchEnd(impl_ptr: *anyopaque, ctx: *DispatchContext) void {
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

    pub fn dispatch(self: RequestDispatcher, ctx: *DispatchContext) anyerror!DispatchResult {
        return self.dispatch_fn(self.impl_ptr, ctx);
    }

    pub fn dispatchEnd(self: RequestDispatcher, ctx: *DispatchContext) void {
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
    pub fn dispatch(self: *MethodRegistry, ctx: *DispatchContext) anyerror!DispatchResult {
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
    pub fn dispatchEnd(self: *MethodRegistry, ctx: *DispatchContext) void {
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

fn testHandler(ctx: *DispatchContext, params: ?std.json.Value) anyerror!DispatchResult {
    _ = params;
    _ = ctx;
    return DispatchResult.withResult("{\"hello\":\"world\"}");
}

fn testErrorHandler(_: *DispatchContext, _: ?std.json.Value) anyerror!DispatchResult {
    return error.TestError;
}

test "MethodRegistry dispatches to handler" {
    const allocator = std.testing.allocator;
    var registry = MethodRegistry.init(allocator);
    defer registry.deinit();

    try registry.add("test", testHandler);

    const request = jsonrpc.Request{ .method = "test" };
    var ctx = DispatchContext{
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
    var ctx = DispatchContext{
        .allocator = allocator,
        .request = &request,
    };

    const result = try registry.dispatch(&ctx);
    try std.testing.expect(result == .err);
    try std.testing.expectEqual(jsonrpc.ErrorCode.MethodNotFound, result.err.code);
}
