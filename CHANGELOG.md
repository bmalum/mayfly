# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0-rc.1] - 2026-09-27

A redesign. See `guides/migrating-from-0.x.md` for the upgrade path.

### Added
- `Mayfly.Handler` behaviour with `init/1` (cold-start state) and `handle/3`;
  `_HANDLER` now names a module. Legacy `Module.function` handlers still work.
- `Mayfly.Release`: `prepare/1`, `bootstrap/1`, `zip/1` release steps – the Lambda
  package is produced by `mix release`. `mayfly: [layer: true]` builds
  ERTS-less zips for the Mayfly Erlang layer.
- ERTS layer tooling in `layer/` (`build.sh` with an OTP version matrix,
  `publish.sh` with pinned + major-alias layer names, idempotent re-runs,
  `--public`/`--org` sharing, `latest-otp.sh`, `publisher-role.yml`) and a
  weekly GitHub Actions workflow that publishes public layers for the latest
  patch of each supported OTP major to 16 regions on native runners.
- `bootstrap` for layer builds verifies the layer is present and its ERTS
  version matches the release before starting the VM.
- `mix lambda.invoke --http [--method M --path P]` wraps the event like a
  Function URL / API Gateway v2 request.
- `mix lambda.build --docker` works with `finch` when docker is absent and
  mounts external `path:` dependencies into the container.
- `mix lambda.doctor` checks the release configuration, resolves the handler
  and runs its `init/1`, and compares the local OTP with a layer's
  (`--layer ARN`).
- `Mayfly.Response.stream/2` accepts `send_timeout:` to bound a stalled
  streaming write (default 30 s).
- `bootstrap` uses a single scheduler (`+S 1:1`) only on standard Lambda;
  on Managed Instances (`AWS_LAMBDA_MAX_CONCURRENCY > 1`) the VM sizes
  schedulers to the vCPUs. Managed Instances verified on real hardware.
- Dialyzer runs in CI; a `Publish` workflow releases to Hex.pm on `v*` tags.
- `Mayfly.Response`: custom content types, response streaming with chunked
  transfer encoding, error trailers and the Function URL HTTP prelude
  (`Mayfly.Response.http/2`).
- `Mayfly.Context`: `invocation_id`, `tenant_id`, `env`; `remaining_time_ms/1`,
  `logger_metadata/1`.
- Lambda Managed Instances: `AWS_LAMBDA_MAX_CONCURRENCY` pollers run
  invocations concurrently in isolated processes.
- Runtime API: `Lambda-Runtime-Invocation-Id` echo, error-type header
  normalised to `Category.Reason`, `Lambda-Runtime-Function-Xray-Error-Cause`,
  `User-Agent`.
- `Mayfly.LogFormatter` (JSON lines for advanced logging controls) installed
  automatically when `AWS_LAMBDA_LOG_FORMAT=JSON`; `AWS_LAMBDA_LOG_LEVEL` /
  `LOGLEVEL` honoured.
- `:telemetry` events (optional dependency).
- `Mayfly.LocalRuntime` emulator and `mix lambda.invoke`.
- `Mayfly.Boot.main/0` explicit entry point; `Mayfly.start_link/1` public API.
- `Runtime.InitError`, `Runtime.InvalidEvent` error types.

### Changed
- Requires Elixir 1.18+; uses the built-in `JSON` module. Jason removed.
- `Mayfly.HTTP` (`:gen_tcp`) replaces `:httpc`; `:inets`/`:ssl` no longer
  required at boot.
- `mix lambda.build` only builds the configured release (optionally in
  Docker) and copies `lambda.zip`; no `MIX_ENV=lambda`, defaults to `prod`.
- `errorType` has no `Elixir.` prefix; `stackTrace` is a list; `{:error, "s"}`
  is `HandlerError`; non-`{:ok,_}/{:error,_}` returns are `Runtime.InvalidResponse`.
- `Runtime.HandlerNotFound` renamed to `Runtime.NoSuchHandler` (AWS-recommended).
- Modules renamed: `Mayfly.Error` → `Mayfly.ErrorPayload`, `Mayfly.Runtime` →
  `Mayfly.RuntimeAPI`, `Mayfly.Loop` → `Mayfly.Poller`.
- `bootstrap` uses `bin/<release> eval "Mayfly.Boot.main()"`, sets
  `RELEASE_TMP=/tmp`, `RELEASE_DISTRIBUTION=none`; `vm.args` tuned for Lambda.
- `lambda.Dockerfile` pins OTP 27.3.4 / Elixir 1.18.4, is multi-target and
  architecture-neutral.

### Removed
- Application callback (`mod:`) – nothing starts implicitly.
- `config :mayfly, start_loop`, `Mayfly.Handler.default_handler`, `Mayfly.hello`, `Mayfly.Helpers`, the committed `bootstrap` file.

### Fixed (relative to 0.1.0)
- Misconfigured handlers were reported as successful invocations.
- Unencodable results left invocations hanging until timeout.
- `exit`/`throw` in handlers crashed the event loop.
- `KeyError` and friends produced `errorMessage: null`.
- Poll failures spun without backoff; HTTP status codes were ignored;
  bodies were charlists.
- `zip` binary dependency, paths with spaces, `--outdir` ignored for Docker.

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
