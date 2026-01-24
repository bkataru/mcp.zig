//! MCP.zig - Model Context Protocol implementation for Zig
//!
//! A Zig library implementing the Model Context Protocol (MCP) specification,
//! enabling seamless communication between AI models and tool providers.
//!
//! ## Quick Start
//!
//! ```zig
//! const mcp = @import("mcp");
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!     const allocator = gpa.allocator();
//!
//!     var registry = mcp.MethodRegistry.init(allocator);
//!     defer registry.deinit();
//!
//!     // Register handlers
//!     try registry.add("initialize", handleInitialize);
//!     try registry.add("tools/list", handleToolsList);
//!     try registry.add("tools/call", handleToolsCall);
//!
//!     // Run server with Content-Length streaming
//!     const stdin = std.fs.File.stdin().reader();
//!     const stdout = std.fs.File.stdout().writer();
//!     try mcp.runContentLengthServer(allocator, stdin, stdout, &registry);
//! }
//! ```

const std = @import("std");
const constants = @import("constants.zig");

// ==================== Core Modules ====================

// MCP Protocol Types
pub const types = @import("types.zig");
pub const Tool = types.Tool;
pub const Resource = types.Resource;
pub const Prompt = types.Prompt;
pub const Content = types.Content;
pub const TextContent = types.TextContent;
pub const InitializeParams = types.InitializeParams;
pub const InitializeResult = types.InitializeResult;
pub const ListToolsResult = types.ListToolsResult;
pub const CallToolParams = types.CallToolParams;
pub const CallToolResult = types.CallToolResult;
pub const ServerCapabilities = types.ServerCapabilities;
pub const ClientCapabilities = types.ClientCapabilities;
pub const Implementation = types.Implementation;
pub const PROTOCOL_VERSION = constants.MCP_PROTOCOL_VERSION;

// JSON-RPC handling
pub const jsonrpc = @import("jsonrpc.zig");
pub const JsonRpc = jsonrpc.JsonRpc;
pub const Request = jsonrpc.Request;
pub const Response = jsonrpc.Response;
pub const RequestId = jsonrpc.RequestId;
pub const ParsedRequest = jsonrpc.ParsedRequest;
pub const ErrorCode = jsonrpc.ErrorCode;
pub const parseRequest = jsonrpc.parseRequest;
pub const buildResponse = jsonrpc.buildResponse;
pub const buildErrorResponse = jsonrpc.buildErrorResponse;

// Dispatcher
pub const dispatcher = @import("dispatcher.zig");
pub const RequestDispatcher = dispatcher.RequestDispatcher;
pub const MethodRegistry = dispatcher.MethodRegistry;
pub const DispatchResult = dispatcher.DispatchResult;
pub const DispatchContext = dispatcher.DispatchContext;
pub const HandlerFn = dispatcher.HandlerFn;

// Streaming
pub const streaming = @import("streaming.zig");
pub const readContentLengthFrame = streaming.readContentLengthFrame;
pub const writeContentLengthFrame = streaming.writeContentLengthFrame;
pub const readDelimiterFrame = streaming.readDelimiterFrame;
pub const writeDelimiterFrame = streaming.writeDelimiterFrame;

// Logging
pub const logger = @import("logger.zig");
pub const Logger = logger.Logger;
pub const NopLogger = logger.NopLogger;
pub const StderrLogger = logger.StderrLogger;
pub const FileLogger = logger.FileLogger;

// ==================== Additional Modules ====================

// Transport layer
pub const transport = @import("transport.zig");
pub const Transport = transport.Transport;
pub const StdioTransport = transport.StdioTransport;
pub const TcpTransport = transport.TcpTransport;
pub const TransportMode = transport.TransportMode;

// Error handling
pub const errors = @import("errors.zig");
pub const McpError = errors.McpError;
pub const JsonRpcError = errors.JsonRpcError;
pub const JsonRpcErrorCode = errors.JsonRpcErrorCode;

// Configuration
pub const config = @import("config.zig");
pub const Config = config.Config;

// Memory management utilities
pub const memory = @import("memory.zig");
pub const ArenaPool = memory.ArenaPool;
pub const ScopedArena = memory.ScopedArena;
pub const MemoryTracker = memory.MemoryTracker;

// Core MCP server
pub const mcp = @import("mcp.zig");
pub const MCPServer = mcp.MCPServer;
pub const MCPTool = mcp.MCPTool;
pub const CancellationToken = mcp.CancellationToken;
pub const Session = mcp.Session;
pub const ServerState = mcp.ServerState;

// Progress notifications
pub const progress = @import("progress.zig");
pub const ProgressToken = progress.ProgressToken;
pub const ProgressTracker = progress.ProgressTracker;
pub const ProgressBuilder = progress.ProgressBuilder;

// ==================== Primitives ====================

pub const primitives = struct {
    pub const tool = @import("primitives/tool.zig");
    pub const ToolRegistry = tool.ToolRegistry;
    pub const ToolHandlerFn = tool.ToolHandlerFn;

    pub const resource = @import("primitives/resource.zig");
    pub const ResourceRegistry = resource.ResourceRegistry;
    pub const ResourceContent = resource.ResourceContent;
    pub const ResourceHandlerFn = resource.ResourceHandlerFn;

    pub const prompt = @import("primitives/prompt.zig");
    pub const PromptRegistry = prompt.PromptRegistry;
    pub const PromptArgument = prompt.PromptArgument;
    pub const PromptMessage = prompt.PromptMessage;
    pub const PromptResult = prompt.PromptResult;
    pub const PromptHandlerFn = prompt.PromptHandlerFn;
};

// Built-in tools
pub const tools = struct {
    pub const calculator = @import("tools/calculator.zig");
    pub const cli = @import("tools/cli.zig");
};

// ==================== Helper Functions ====================

/// Create a simple text content response
pub fn textContent(text: []const u8) Content {
    return types.textContent(text);
}

/// Create a simple tool definition
pub fn simpleTool(name: []const u8, description: []const u8) Tool {
    return types.simpleTool(name, description);
}

// ==================== Tests ====================

test {
    // Run all tests from submodules
    std.testing.refAllDecls(@This());
}
