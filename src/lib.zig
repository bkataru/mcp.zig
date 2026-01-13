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
//!     var server = try mcp.MCPServer.init(allocator);
//!     defer server.deinit();
//!
//!     // Register a custom tool
//!     try server.registerTool(.{
//!         .name = "my_tool",
//!         .description = "My custom tool",
//!         .handler = myToolHandler,
//!     });
//!
//!     // Handle requests...
//! }
//! ```

const std = @import("std");

// Core MCP protocol implementation
pub const mcp = @import("mcp.zig");
pub const MCPServer = mcp.MCPServer;
pub const MCPTool = mcp.MCPTool;
pub const Session = mcp.Session;
pub const ServerState = mcp.ServerState;
pub const PROTOCOL_VERSION = mcp.PROTOCOL_VERSION;

// Transport layer
pub const transport = @import("transport.zig");
pub const Transport = transport.Transport;
pub const StdioTransport = transport.StdioTransport;
pub const TcpTransport = transport.TcpTransport;
pub const TransportMode = transport.TransportMode;

// JSON-RPC handling
pub const jsonrpc = @import("jsonrpc.zig");
pub const JsonRpc = jsonrpc.JsonRpc;
pub const Request = jsonrpc.Request;
pub const RequestId = jsonrpc.RequestId;
pub const ParsedRequest = jsonrpc.ParsedRequest;
pub const ErrorCode = jsonrpc.ErrorCode;

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

// Primitives
pub const primitives = struct {
    pub const tool = @import("primitives/tool.zig");
    pub const Tool = tool.Tool;
    pub const ToolRegistry = tool.ToolRegistry;
    pub const ToolHandlerFn = tool.ToolHandlerFn;

    pub const resource = @import("primitives/resource.zig");
    pub const Resource = resource.Resource;

    pub const prompt = @import("primitives/prompt.zig");
    pub const Prompt = prompt.Prompt;
};

// Built-in tools
pub const tools = struct {
    pub const calculator = @import("tools/calculator.zig");
    pub const cli = @import("tools/cli.zig");
};

// Re-export common types at top level for convenience
pub const Tool = primitives.Tool;
pub const ToolRegistry = primitives.ToolRegistry;

test {
    // Run all tests from submodules
    std.testing.refAllDecls(@This());
}
