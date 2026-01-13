//! Protocol and System Constants
//!
//! Centralized constants to eliminate magic numbers and strings
//! throughout the codebase for better maintainability.

/// Protocol Versions
pub const JSON_RPC_VERSION = "2.0";
pub const MCP_PROTOCOL_VERSION = "2025-11-25";
pub const SERVER_VERSION = "1.0.0";

/// Network Configuration
pub const DEFAULT_HOST = "127.0.0.1";
pub const DEFAULT_PORT = 8080;
pub const DEFAULT_CONNECTION_TIMEOUT_MS = 30000;
pub const DEFAULT_MAX_REQUEST_SIZE = 1024 * 1024; // 1MB

/// Performance and Timing
pub const DEFAULT_COMMAND_TIMEOUT_MS = 5000;
pub const MEMORY_STATS_INTERVAL = 100;
pub const DEBUG_DELAY_MS = 1;
pub const SLEEP_INTERVAL_NS = 1 * std.time.ns_per_ms;

/// Message Format Constants
pub const INIT_REQUEST_TEMPLATE =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"clientInfo":{"name":"{s}","version":"1.0.0"}}}
;

const std = @import("std");
