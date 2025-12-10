# Changelog

All notable changes to tidewave_rails will be documented in this file.

## [0.4.1] - 2024-12-09

### Fixed
- **CRITICAL:** Request correlation now works correctly across frontend and backend
  - `Tidewave::Middleware` now reads `env['action_dispatch.request_id']` instead of `HTTP_X_REQUEST_ID`
  - `Tidewave::ExceptionsMiddleware` now uses `request.uuid` directly
  - This ensures backend exception logs use the same UUID that frontend captures via `X-Vibes-Request-ID`
  - Fixes correlation detection in `ExceptionAnalysisTool` (frontend ↔ backend error linking)
  - **Does NOT overwrite Fly's `X-Request-ID`** - preserves both tracing systems
  
### Added
- `X-Vibes-Request-ID` header now echoed in all Tidewave middleware responses
- Dual tracing support: `X-Vibes-Request-ID` (Rails UUID for app correlation) + `X-Request-ID` (Fly proxy ID for infrastructure tracing)

### Changed
- Request ID sourcing: Now uses Rails' internal UUID from `ActionDispatch::RequestId` middleware
- This matches the UUID sent to frontend via `X-Vibes-Request-ID` header from `ApplicationController`

## [0.4.0] - 2024-12-08

### Added
- Initial release with MCP (Model Context Protocol) support
- Exception tracking middleware for backend errors
- Async job logging for visibility into background job failures
- Tools: get_logs, get_models, get_docs, get_source_location, get_async_job_logs, get_solid_queue_failures
- Security: Bearer token auth, IP allowlist, mode-based tool filtering (readonly/full)
- Shell endpoint for programmatic command execution (full mode only)
