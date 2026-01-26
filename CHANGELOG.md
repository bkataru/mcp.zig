# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **BREAKING:** Migrated from deprecated `std.io` APIs to new `std.Io` APIs (Zig 0.15.x compatibility)
  - `streaming.zig`: Functions now use `GenericReader` API (`readByte`/`readNoEof`) instead of deprecated reader methods
  - `network.zig`: Connection stores heap-allocated buffers with `reader()`/`writer()` methods
  - `lib.zig`: Updated I/O type references for new API compatibility

### Fixed
- `streaming.zig`: Use correct `GenericReader` API methods (`readByte`, `readNoEof`) for `fixedBufferStream().reader()`

## [0.2.0] - 2026-01-24

### Changed
- **BREAKING:** Major restructure for Zig 0.15.2+ compatibility
- Updated all I/O and ArrayList APIs for Zig 0.15.x compatibility
- Exported `mcp` module for external package consumers

### Added
- **Progress Notifications**: Full `ProgressBuilder` and `ProgressTracker` implementation in `progress.zig`
- **Resource Subscriptions**: Complete `subscribe()` and `unsubscribe()` with subscription tracking (100% MCP spec compliance)
- **Comprehensive Examples**:
  - `async_progress_example.zig` - Async progress tracking
  - `calculator_example.zig` - Tool registration patterns
  - `cancellation_example.zig` - Request cancellation handling
  - `client_server_example.zig` - Client-server communication
  - `comprehensive_example.zig` - Full-featured MCP server
  - `file_server.zig` - File system resource server
  - `hello_mcp.zig` - Minimal getting started example
  - `integration_test.zig` - Integration test suite
  - `mcp_client_example.zig` - MCP client implementation
  - `progress_example.zig` - Progress notification usage
  - `prompts_example.zig` - Prompt template registration
  - `resource_subscriptions.zig` - Resource subscription patterns
  - `resource_templates_example.zig` - Dynamic resource templates
  - `sampling_example.zig` - LLM sampling integration
  - `tcp_client_example.zig` - TCP transport client
  - `tcp_full_example.zig` - Complete TCP implementation
  - `tcp_server_example.zig` - TCP transport server
- Pure Zig test client (replaced Python/PowerShell scripts)
- Comprehensive test coverage: 103/103 tests passing
- `SPEC_COMPLIANCE.md` - MCP specification compliance audit
- Dispatcher lifecycle hooks: `onBefore`, `onAfter`, `onError`, `onFallback`
- Enhanced JSON utilities in `json_utils.zig`
- Memory management utilities in `memory.zig`
- Logger interface with multiple implementations

### Fixed
- Memory leaks in progress notification tests
- Memory management in `Connection.close()` and `deinit()`
- Example compilation issues for Zig 0.15.2 API compatibility

### Removed
- Python/PowerShell test scripts (replaced with pure Zig test client)

## [0.1.0] - 2025-05-29

### Added
- Initial MCP (Model Context Protocol) implementation
- JSON-RPC 2.0 message handling with proper error codes
- Content-Length streaming (LSP/MCP protocol standard) in `streaming.zig`
- Stdio and TCP transport support in `transport.zig` and `network.zig`
- **Tool System**:
  - Tool registration with typed parameter handling
  - Input schema validation (JSON Schema)
  - Tool execution with proper result/error handling
- **Resource System**:
  - Resource registration with URI-based lookup
  - `resources/list` and `resources/read` handlers
  - Resource descriptions and MIME type support
  - Optional handlers for dynamic content
- **Prompt System**:
  - Prompt registration with name-based lookup
  - `prompts/list` and `prompts/get` handlers
  - Typed argument support with descriptions
  - Optional handlers for dynamic prompt generation
- Method dispatcher with extensible handler registration
- Configuration system in `config.zig`
- Error handling with MCP-compliant error codes in `errors.zig`
- Type definitions in `types.zig` and `primitives/`
- Calculator and CLI tool examples
- Zero dependencies - pure Zig standard library only
