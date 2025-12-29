# CHANGELOG

## VIBES (rolling edge)

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

## v0.4.1 (2025-11-25)

* Fix compatibility with hash fields in Dry schema

## v0.4.0 (2025-10-17)

* Use Streamable HTTP transport
* Allow logger middleware to be customizable
* Use FastMCP ~> 1.6.0

## v0.3.1 (2025-09-16)

* Optimize `get_logs`
* Fix `get_models` tool to filter Sequel anonymous models
* Remove unused credentials support

## v0.3.0 (2025-09-08)

* Add `grep` option to `get_logs`
* Bundle `get_package_location` into `get_source_location`
* Support team configuration
* Remove deprecated file system tools

## v0.2.0 (2025-08-12)

* Support Tidewave Web
* Add Sequel ORM support
* Return Ruby inspection instead of JSON in tools
* Add `get_docs`
* Use a separate log file for Tidewave
* Remove `package_search` as it was rarely used as its output is limited to avoid injections

## v0.1.3

* Merge `glob_project_files` tool into `list_project_files`
* Add `get_package_location` tool
* Add `line_offset` and `count` parameters to `read_project_file` tool
* Add Ruby syntax validation before writing `.rb` files
* Rename `get_source_location` parameter to "reference", which expects either `String.new` or `String#gsub`
* Add download counts to package information

## v0.1.2

* Also support Rails 7.1
* Load class core extension before using it
* Allow configuration from Rails

## v0.1.1

* Bump to fast-mcp 1.3.1
* Do not attempt to missing generator fixtures
* Drop `Faraday` in favor of `Net::HTTP` for RubyGems API calls

## v0.1.0

* Initial release
