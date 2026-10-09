# 🪰 Mayfly

<div align="center">
  <img width="300" src="https://raw.githubusercontent.com/bmalum/mayfly/main/mayfly.png" alt="Mayfly – Elixir on AWS Lambda logo"/>
  <h3>A lightweight AWS Lambda Custom Runtime for Elixir</h3>

  ![Version](https://img.shields.io/badge/version-1.0.0--rc.1-blue)
  ![Elixir](https://img.shields.io/badge/elixir-%3E%3D%201.18-blueviolet)
  ![License](https://img.shields.io/badge/license-MIT-green)
</div>

## Why Mayfly?

- **A behaviour, not a string** – `use Mayfly.Handler`, implement `handle/3`, optionally `init/1` for cold-start work. Compile-time checked.
- **`mix release` is the build** – add the `Mayfly.Release` steps to your release and get `lambda.zip`. No special `MIX_ENV`, umbrellas and multiple releases work.
- **No Docker needed** – with the Mayfly ERTS layer your zip contains only BEAM files and builds on any OS in seconds.
- **Honest error reporting** – exceptions, exits, bad return values, unencodable results and misconfigured handlers all reach Lambda as proper errors with Elixir stack traces.
- **Current Lambda features** – response streaming (incl. Function URL preludes), tenant isolation, invocation ids, Managed Instances concurrency, JSON structured logging, X-Ray trace propagation.
- **Zero runtime dependencies** – built-in `JSON`, own HTTP client over `:gen_tcp`; `:telemetry` optional.
- **Nothing starts implicitly** – Mayfly has no application callback; `mix test` and `iex` in your project are untouched.

## Quick start

```elixir
# mix.exs
def project do
  [
    app: :my_app,
    releases: [
      lambda: [
        steps: [&Mayfly.Release.prepare/1, :assemble, &Mayfly.Release.bootstrap/1, &Mayfly.Release.zip/1],
        mayfly: [handler: MyApp.Handler, layer: true]
      ]
    ],
    deps: [{:mayfly, "~> 1.0.0-rc"}]
  ]
end
```

```elixir
# lib/my_app/handler.ex
defmodule MyApp.Handler do
  use Mayfly.Handler

  @impl true
  def handle(event, %Mayfly.Context{} = ctx, _state) do
    {:ok, %{message: "Hello from Elixir!", request_id: ctx.request_id, event: event}}
  end
end
```

```bash
mix lambda.invoke MyApp.Handler '{"name":"world"}'   # run it locally
MIX_ENV=prod mix release lambda                       # -> _build/prod/rel/lambda/lambda.zip

aws lambda create-function --function-name hello \
  --runtime provided.al2023 --architectures arm64 \
  --handler MyApp.Handler --zip-file fileb://_build/prod/rel/lambda/lambda.zip \
  --layers arn:aws:lambda:eu-central-1:ACCOUNT:layer:mayfly-erlang-27-3-4-arm64:1 \
  --role arn:aws:iam::ACCOUNT:role/lambda-role
```

## Table of contents

- [Requirements](#requirements)
- [Writing a handler](#writing-a-handler)
- [Responses](#responses)
- [Errors](#errors)
- [Building](#building)
- [Local development](#local-development)
- [Observability](#observability)
- [Lambda Managed Instances](#lambda-managed-instances)
- [Documentation](#documentation)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)

## Requirements

| | Supported |
|---|---|
| Elixir | 1.18 or newer |
| Erlang/OTP | 27, 28 or 29; public layers exist for the latest patch of each (OTP 29 needs Elixir ≥ 1.20) |
| Lambda | `provided.al2023`, x86_64 or arm64; Lambda (default) and Managed Instances |

Upgrading from 0.x? See [guides/migrating-from-0.x.md](guides/migrating-from-0.x.md).

## Writing a handler

```elixir
defmodule MyApp.Handler do
  use Mayfly.Handler

  # Optional. Runs once per execution environment before the first event.
  @impl true
  def init(_opts) do
    {:ok, %{table: System.fetch_env!("TABLE_NAME")}}
  end

  @impl true
  def handle(event, %Mayfly.Context{} = ctx, state) do
    case MyApp.Items.fetch(state.table, event["id"]) do
      {:ok, item} -> {:ok, item}
      :not_found -> {:error, %{errorType: "NotFound", errorMessage: "no item #{event["id"]}"}}
    end
  end
end
```

Set the Lambda **Handler** to `MyApp.Handler`. `event` is the decoded JSON payload (string keys). `Mayfly.Context` gives you `request_id`, `invocation_id`, `deadline_ms` (`Mayfly.Context.remaining_time_ms/1`), `function_arn`, `trace_id`, `tenant_id` and the static function config in `env`.

Legacy `Module.function` handlers (arity 1 or 2) still work; see the migration guide.

### Event sources

`Mayfly.Events` decodes the envelopes AWS services send: API Gateway / Function URL requests (`body` already a map), SQS, SNS, S3 (URL-decoded keys), EventBridge, Kinesis and DynamoDB Streams (attribute values as plain terms), with partial-batch helpers:

```elixir
case Mayfly.Events.decode(event) do
  {:ok, %Mayfly.Events.HTTP.Request{method: "POST", body: body} = req} -> Mayfly.Events.HTTP.json(201, create(body), req)
  {:ok, %Mayfly.Events.SQS{} = sqs} -> {:ok, Mayfly.Events.SQS.process_batch(sqs, &process/1)}
  :unknown -> {:ok, event}
end
```

See [guides/events.md](guides/events.md). `mix lambda.invoke … --event sqs` (or `s3`, `eventbridge`, `dynamodb`, …) wraps a payload in a realistic envelope for local testing.

## Responses

`{:ok, value}` with any JSON-encodable value is sent as `application/json`. For anything else use `Mayfly.Response`:

```elixir
# binary body
{:ok, %Mayfly.Response{body: png, content_type: "image/png"}}

# API Gateway / Function URL (buffered) – just return the proxy map
{:ok, %{statusCode: 200, headers: %{"content-type" => "text/html"}, body: html}}

# streaming (Function URL with RESPONSE_STREAM or InvokeWithResponseStream)
{:ok,
 %Mayfly.Response{body: Stream.map(tokens, &sse/1), content_type: "text/event-stream"}
 |> Mayfly.Response.stream()
 |> Mayfly.Response.http(status: 200, headers: %{"cache-control" => "no-cache"})}
```

See [guides/streaming.md](guides/streaming.md).

## Errors

| Situation | `errorType` | Header (`Lambda-Runtime-Function-Error-Type`) |
|---|---|---|
| Exception raised | module name, e.g. `KeyError` | `Function.KeyError` |
| `{:error, "text"}` / `{:error, term}` | `HandlerError` | `Function.HandlerError` |
| `{:error, %{errorType: t, errorMessage: m}}` | `t` | `Function.<t without dots>` |
| `exit/1`, `throw/1` | `Exit`, `Throw` | `Function.Exit` / `Function.Throw` |
| return value not `{:ok, _}`/`{:error, _}`, or not encodable | `Runtime.InvalidResponse` | same |
| event body not JSON | `Runtime.InvalidEvent` | same |
| `_HANDLER` not resolvable | `Runtime.NoSuchHandler` (init error) | same |
| `init/1` fails | `Runtime.InitError` (init error) | same |

`stackTrace` is a list of frames with Mayfly's own frames removed. Everything in `{:error, reason}` ends up in the payload, which API Gateway may forward – keep secrets out of it.

## Building

Two ways to get an ERTS that matches Lambda:

**1. ERTS layer (recommended).** `mayfly: [layer: true]` builds the release with `include_erts: false`; the zip has only BEAM files (a few MB) and builds anywhere. Attach a `mayfly-erlang-<otp>-<arch>` layer to the function: public layers for the latest patch of each supported OTP major are published weekly to 16 regions (catalog and JSON resolver at [elixir-aws-lambda.dev/layers](https://elixir-aws-lambda.dev/layers/)), or publish to your own account with `layer/build.sh` and `layer/publish.sh`. Your build toolchain must use the layer's exact OTP version (`mise use erlang@27.3.4.18`); `bootstrap` verifies this at start. See [guides/layers.md](guides/layers.md).

**2. Bundled ERTS.** Leave `layer` off and build on Amazon Linux 2023 or in Docker:

```bash
mix lambda.build --docker --arch arm64      # docker or finch; uses lambda.Dockerfile, copies lambda.zip to .
```

Drop a `lambda.Dockerfile` into your project to add system libraries for NIFs.

`Mayfly.Release.prepare/1` applies `strip_beams`, Unix-only executables and a Lambda-tuned `vm.args` (no busy waiting, no distribution; a single scheduler on standard Lambda, all vCPUs on Managed Instances). Override any of it by setting the option yourself in the release config.

## Local development

```bash
mix lambda.invoke MyApp.Handler '{"id": 1}'                 # inline JSON
mix lambda.invoke MyApp.Handler event.json                  # from a file
mix lambda.invoke MyApp.Handler.legacy_fun -                # from stdin
mix lambda.invoke MyApp.Handler '{"id": 1}' --http --path /items   # wrapped like a Function URL event
mix lambda.doctor --layer arn:aws:lambda:…:layer:mayfly-erlang-27-arm64:1   # release config, handler, OTP vs layer
```

`mix lambda.invoke` runs the real runtime (handler resolution, `init/1`, context, error formatting, streaming) against `Mayfly.LocalRuntime`, an in-process Runtime API emulator you can also use in ExUnit:

```elixir
{:ok, rt} = Mayfly.LocalRuntime.start_link()
{:ok, _} = Mayfly.start_link(handler: "MyApp.Handler", runtime_api: Mayfly.LocalRuntime.address(rt))
assert {:ok, %{body: body}} = Mayfly.LocalRuntime.invoke(rt, %{"id" => 1})
```

For a faithful emulation (timeouts, cold starts) use [aws-lambda-rie](https://github.com/aws/aws-lambda-runtime-interface-emulator) with the built zip.

## Observability

- **Logs**: set the function's log format to JSON (advanced logging controls) and Mayfly emits `{"timestamp","level","requestId","tenantId","message",...}` lines via `Mayfly.LogFormatter`; `AWS_LAMBDA_LOG_LEVEL`/`LOGLEVEL` set the level. `request_id`, `tenant_id` and `trace_id` are in `Logger.metadata` during every invocation.
- **Telemetry** (optional dep): `[:mayfly, :init, :stop]`, `[:mayfly, :invocation, :start | :stop]`, `[:mayfly, :poll, :error]`.
- **X-Ray**: `_X_AMZN_TRACE_ID` is exported per invocation; errors carry an X-Ray cause header.

See [guides/observability.md](guides/observability.md).

## Lambda Managed Instances

Mayfly starts `AWS_LAMBDA_MAX_CONCURRENCY` pollers, each an isolated process, so a single execution environment serves that many invocations in parallel (verified on real Managed Instances: 8 concurrent invocations, one VM, 0.13 s wall time). Handler `state` from `init/1` is shared read-only. Managed Instances do not kill a handler at its deadline – check `Mayfly.Context.remaining_time_ms/1` in long loops. Requires `--memory-size` ≥ 2048 and a capacity provider; see the deployment guide.

## Documentation

Full documentation: **[elixir-aws-lambda.dev/docs](https://elixir-aws-lambda.dev/docs/)**

### For coding agents

`skills/mayfly-elixir-lambda/` is an [Agent Skill](https://agentskills.io) (Kiro, Claude Code, Cursor, Codex, …) that teaches an agent the handler behaviour, the release build, local testing and the failure modes:

```bash
# project-local install for Kiro or Claude Code
cp -r deps/mayfly/skills/mayfly-elixir-lambda .kiro/skills/      # or .claude/skills/
```

The docs are also published as Markdown with an index at [elixir-aws-lambda.dev/docs/llms.txt](https://elixir-aws-lambda.dev/docs/llms.txt).

- [Getting started](guides/getting-started.md)
- [Event sources](guides/events.md) – typed decoders for API Gateway, SQS, SNS, S3, EventBridge, Kinesis, DynamoDB Streams
- [Deployment](guides/deployment.md) – layer vs bundled ERTS, Docker, IaC snippets
- [Erlang runtime layers](guides/layers.md) – public ARNs, naming, self-hosting, automation
- [Streaming](guides/streaming.md)
- [Observability](guides/observability.md)
- [Architecture](guides/architecture.md)
- [Migrating from 0.x](guides/migrating-from-0.x.md)

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Runtime.NoSuchHandler` at start | Handler setting is not a module in the release, or the module lacks `use Mayfly.Handler`. The message names what was tried |
| `Runtime.InitError` | Your `init/1` returned `{:error, _}` or raised; message and stack trace are in the payload |
| `Runtime.InvalidResponse` | Returned something other than `{:ok, _}`/`{:error, _}`, or a value `JSON` cannot encode (tuples, structs without `JSON.Encoder`) |
| `Mayfly: no Erlang runtime at /opt/erlang` | No layer attached (or wrong architecture). Attach the `mayfly-erlang-…-<arch>` layer |
| `Mayfly: release was built for ERTS X but the layer provides Y` | Toolchain OTP differs from the layer's. Build with the exact OTP version of the layer (`mise use erlang@…`) or attach the matching layer |
| `exec format error` | Bundled ERTS built for the wrong architecture; rebuild with `--docker --arch` |
| Handler gets `%{"requestContext" => …, "body" => "…"}` | Function URL / API Gateway wrap the payload; use `Mayfly.Events.HTTP.decode/1` (`body` is decoded for you). Test locally with `mix lambda.invoke --event apigw-v2` |
| Nothing happens in `iex`/`mix test` | Expected: Mayfly only runs when `bootstrap` calls `Mayfly.Boot.main/0` or you call `Mayfly.start_link/1` |
| Console shows buffered response for a streaming function | Normal; the console never streams. Use a Function URL with `RESPONSE_STREAM` or `InvokeWithResponseStream` |

## Contributing

Run `mix format`, `mix compile --warnings-as-errors` and `mix test` before opening a PR; CI enforces all three plus a release build. `AGENTS.md` describes the architecture, invariants and release/layer procedures for contributors and coding agents; `skills/mayfly-maintainer/` is the operational runbook.

## License

MIT – see the `LICENSE` file.
