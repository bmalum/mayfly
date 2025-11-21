# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2025-11-21

### Added
- Initial release of Mayfly - AWS Lambda Custom Runtime for Elixir
- Core Lambda Runtime API integration with long-polling support
- Handler resolution and execution with proper error handling
- Comprehensive error formatting with stacktraces
- Mix task `lambda.build` for creating deployment packages
- Docker build support for cross-platform compatibility
- ZIP archive creation for Lambda deployment
- Bootstrap script generation
- Security: Using `String.to_existing_atom/1` to prevent atom exhaustion
- Timeout configuration: 5s for responses, infinite for long-polling
- Graceful error handling for missing request IDs and malformed JSON
- OTP supervision tree for fault tolerance
- Comprehensive documentation and README with examples

### Features
- Zero boilerplate Lambda function development
- Native Elixir experience with standard `{:ok, result}` / `{:error, reason}` patterns
- Support for API Gateway, S3, EventBridge and other AWS event sources
- Proper Elixir stacktraces in Lambda error responses
- Flexible handler configuration via `_HANDLER` environment variable
- Build tooling with `--zip`, `--docker`, and `--outdir` options

### Technical Details
- Elixir ~> 1.15 support
- Single dependency: Jason for JSON encoding/decoding
- Uses Erlang's `:httpc` for Lambda Runtime API communication
- GenServer-based event loop for continuous invocation processing
