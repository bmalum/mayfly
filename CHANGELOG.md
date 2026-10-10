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
  (`--layer ARN`); without `--layer` it looks the matching public layer up in
  the catalog at elixir-aws-lambda.dev/layers for `--arch`/`--region`.
- Dialyzer PLTs are kept in `_build/plts` (a `priv/plts` location was shipped
  into consumer releases).
- The Layers workflow publishes the ARN index to the website catalog
  (`/layers/` page and static JSON resolver).
- `Mayfly.Response.stream/2` accepts `send_timeout:` to bound a stalled
  streaming write (default 30 s).
- `bootstrap` uses a single scheduler (`+S 1:1`) only on standard Lambda;
  on Managed Instances (`AWS_LAMBDA_MAX_CONCURRENCY > 1`) the VM sizes
  schedulers to the vCPUs. Managed Instances verified on real hardware.
- Dialyzer runs in CI; a `Publish` workflow releases to Hex.pm on `v*` tags.
- `skills/mayfly-elixir-lambda`: an Agent Skill for coding agents, shipped in
  the Hex package.
- `Mayfly.Events`: typed decoders for API Gateway v1/v2 and Function URL
  requests (`Mayfly.Events.HTTP` with JSON/base64-decoded bodies and response
  helpers `json/4`, `text/4`, `binary/5`, `redirect/3`, `respond/4`), SQS, SNS
  (incl. SNS-in-SQS envelopes), S3 (URL-decoded keys), EventBridge, Kinesis and
  DynamoDB Streams (attribute values converted to terms); `process_batch/2`
  partial-batch helpers for SQS, Kinesis and DynamoDB; `Mayfly.Events.decode/1`
  dispatcher. Verified on Lambda with a Function URL, SQS
  `ReportBatchItemFailures`, S3 notifications, EventBridge and DynamoDB Streams.
- `mix lambda.new --http-api`: API Gateway HTTP API (`$default` route, JSON
  access logs, permission) in the SAM, Terraform and CDK templates; deployed
  and exercised on Lambda.
- `mix lambda.doctor` reads the IaC files `mix lambda.new` generates and
  checks OTP major, selected layer ARN, architecture and runtime against the
  toolchain.
- Guides: new `operations.md` (alarms, Logs Insights queries, cost, Managed
  Instances sizing, runbook) and `iac.md` (split out of the deployment guide).
- `Mayfly.Shutdown` + the `mayfly-shutdown` external extension layer: with the
  layer attached Lambda sends SIGTERM before discarding the environment; Mayfly
  emits `[:mayfly, :shutdown]`, runs registered hooks (1 s each), flushes
  Logger and halts. Verified on Lambda; no measurable cold-start cost.
  `layer/build-shutdown-extension.sh`, `layer/publish-shutdown.sh`, workflow job.
- CI: OTP 29 and arm64 rows, container-image job invoking through the Runtime
  Interface Emulator; `layers.yml` gained an opt-in post-publish smoke matrix
  (every OTP major × architecture deployed and invoked on Lambda).
- `ROADMAP.md` with the Durable Functions PR-FAQ.
- `Mayfly.Extension` (opt-in, `MAYFLY_EXTENSION=1`): internal Lambda extension
  that subscribes to the Telemetry API and emits `[:mayfly, :platform, type]`
  `:telemetry` events with the record metrics; `Mayfly.Metrics.attach_platform_metrics/2`
  publishes `Duration`, `BilledDuration`, `MaxMemoryUsed`, `MemorySize`,
  `InitDuration` as EMF. `Mayfly.LocalRuntime` emulates the Extensions and
  Telemetry APIs (`push_telemetry/2`, `shutdown/2`). `Mayfly.HTTP.put/5`.
  Verified on Lambda; no measurable cold-start cost. Lambda does not deliver
  SHUTDOWN to internal extensions, so there is no shutdown hook.
- `mix lambda.new PATH [--iac sam|terraform|cdk] [--arch] [--otp] [--region]`:
  generates a project (handler with HTTP branch, release config,
  `.tool-versions` pinned to the layer's OTP from the catalog, LocalRuntime
  test, README) plus a working SAM, Terraform or CDK definition.
- `templates/` with SAM, Terraform and a CDK `MayflyFunction` construct whose
  layer ARN maps (16 regions × OTP 27/28/29 × arch) are rendered from the
  catalog by `layer/render-templates.sh`, run weekly by the layers workflow.
  All three deployed, invoked and destroyed from generated projects.
- `mix lambda.build --image [--tag] [--push ECR_URI]`: container image for
  Lambda's image package type. Release built in the AL2023 build container,
  image based on `public.ecr.aws/lambda/provided:al2023` with the handler as
  `CMD`, `lambda.image.Dockerfile` override, ECR login/tag/push with digest,
  attestations disabled (Lambda rejects OCI indexes with them). Verified with
  a bcrypt C NIF on arm64: local RIE invoke and Lambda, cold start median
  433 ms once cached.
- `Mayfly.Metrics`: CloudWatch Embedded Metric Format (`emit/3`, `count/4`,
  `timing/4`, `build/3`) and `attach_invocation_metrics/2` emitting
  `Duration`/`Errors`/`ColdStart` per invocation. Verified end to end:
  datapoints appear in CloudWatch under the namespace.
- Companion package [`mayfly_plug`](https://github.com/bmalum/mayfly_plug):
  `Mayfly.Plug.Adapter` (`Plug.Conn.Adapter` for API Gateway v1/v2, Function
  URL and ALB events) and `use Mayfly.Plug.Handler, plug: …` to run Plug
  routers and Phoenix endpoints as handlers, with response streaming for
  `send_chunked`; `guides/phoenix.md` with measured cold starts.
- Companion package [`mayfly_aws`](https://github.com/bmalum/mayfly_aws) with
  `Mayfly.Idempotency` (DynamoDB-backed exactly-once execution), a minimal
  signed DynamoDB client and `Mayfly.AWS.SigV4`; `guides/idempotency.md`.
- Optional `:telemetry` calls go through `apply/3`, so consumers without the
  dependency compile warning-free.
- `mix lambda.invoke --event SOURCE` wraps a payload in a realistic envelope
  (`apigw-v2 apigw-v1 alb sqs sns s3 eventbridge kinesis dynamodb`); `--http`
  is now an alias for `--event apigw-v2`.
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

### Fixed (pre-release review, 2026-10-10)

- Each invocation runs in its own monitored process: a linked process dying or
  `Process.exit/2` from handler code is reported to Lambda as an `Exit` error
  instead of killing the poller and timing the invocation out.
- Error reports can no longer fail themselves: non-UTF-8 `errorMessage`/`errorType`
  are inspected, list bodies are validated as iodata, and a last-resort catch
  reports `Runtime.Unknown`. Error types with `Runtime.`/`Function.` prefixes are
  sanitised for the header; stack traces are trimmed at the handler boundary only.
- `Mayfly.Response.stream/2`'s `send_timeout` is honoured (it was stored but not
  passed on). Encode failures count as errors in telemetry.
- `Mayfly.Boot` only sets the log level when `LOGLEVEL`/`AWS_LAMBDA_LOG_LEVEL`
  is set, and reports application start failures via `/init/error`.
- `init/1` is only called on `Mayfly.Handler` modules, not legacy `Module.function` handlers.
- `rel/overlays` keeps working alongside Mayfly's release templates; `--docker`
  builds pass the toolchain's OTP/Elixir as build args so layer-mode releases match
  the public layer; container images no longer include `lambda.zip`.
- ALB `source_ip` is the last `X-Forwarded-For` hop; v2 responses join list-valued headers.
- `Mayfly.Extension` retries `/event/next` with backoff and halts after repeated
  failures instead of leaving invocations to time out; the listener binds to
  loopback; the accept loop survives transient errors.
- `Mayfly.Shutdown` bounds all hooks by a 1.2 s deadline; `register/1` is a
  no-op outside Lambda.
- Hex package excludes `layer/dist` and `priv/plts`, ships only the user skill,
  and the publish workflow refuses packages over 2 MB.

### Considered and not shipped

- An Elixir layer (`mayfly-elixir-<vsn>-otp-<major>`, zip 0.16 MB instead of
  1.6 MB). Measured on Lambda: cold start median 511 ms vs 543 ms with the
  ERTS layer alone (21 forced cold starts each, arm64, 512 MB), p90 541 vs
  709 ms, deploy upload about one second faster. Below the 50 ms bar for a
  second version axis; see "Why there is no Elixir layer" in the layers guide.

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
