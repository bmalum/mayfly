# Handler patterns

## Behaviour

```elixir
@callback init(opts :: keyword()) :: {:ok, state} | {:error, term}     # optional, once per environment
@callback handle(event :: term, ctx :: Mayfly.Context.t(), state) ::
            {:ok, term | Mayfly.Response.t()} | {:error, term}
```

`event` is the decoded JSON (string keys). `state` is shared read-only across
invocations (and across concurrent pollers on Managed Instances).

## Context fields

`request_id`, `invocation_id`, `deadline_ms`, `function_arn`, `trace_id`,
`tenant_id`, `client_context`, `cognito_identity`, `env` (function name,
version, memory, region, log group/stream). Helpers:
`Mayfly.Context.remaining_time_ms/1`, `Mayfly.Context.logger_metadata/1`.

## Event shapes – use `Mayfly.Events`

```elixir
alias Mayfly.Events
alias Mayfly.Events.{HTTP, SQS, S3, EventBridge, DynamoDB}

def handle(event, _ctx, _s) do
  case Events.decode(event) do
    # Function URL / API Gateway (v1, v2, ALB): body already JSON-decoded, headers lowercased
    {:ok, %HTTP.Request{method: "POST", path: "/items", body: body} = req} ->
      HTTP.json(201, create(body), req, cookies: ["sid=…"])      # right shape for v1/v2/ALB

    {:ok, %HTTP.Request{} = req} ->
      HTTP.text(404, "not found", req)

    # SQS with partial batch failures (ESM needs ReportBatchItemFailures)
    {:ok, %SQS{} = sqs} ->
      {:ok, SQS.process_batch(sqs, fn r -> process(r.body) end)}   # {:error,_}/raise => retried

    {:ok, %S3{records: recs}} -> {:ok, for(r <- recs, do: ingest(r.bucket, r.key))}  # key URL-decoded
    {:ok, %EventBridge{detail_type: "OrderPlaced", detail: d}} -> {:ok, place(d)}
    {:ok, %DynamoDB{records: recs}} -> {:ok, for(%{event_name: :insert, new_image: i} <- recs, do: i)}
    :unknown -> {:ok, %{echo: event}}
  end
end
```

Also `Mayfly.Events.SNS` (and `SNS.from_envelope/1` for SNS→SQS), `Mayfly.Events.Kinesis`.
Response helpers: `HTTP.respond/4`, `json/4`, `text/4`, `binary/5` (base64), `redirect/3`.
Full guide: https://elixir-aws-lambda.dev/docs/events.md

## Errors

```elixir
{:error, "text"}                                         # errorType "HandlerError"
{:error, %{errorType: "NotFound", errorMessage: "..."}}  # passed through as-is
raise MyApp.Error, "..."                                 # errorType "MyApp.Error", stack trace included
```

Do not put secrets in `{:error, reason}`: it becomes the Lambda error payload
and API Gateway may forward it.

## Responses

```elixir
{:ok, %{any: "json"}}                                                # application/json
{:ok, %Mayfly.Response{body: png, content_type: "image/png"}}        # binary
{:ok, %Mayfly.Response{body: Stream.map(tokens, &sse/1), content_type: "text/event-stream"}
      |> Mayfly.Response.stream(send_timeout: 10_000)
      |> Mayfly.Response.http(status: 200, headers: %{"cache-control" => "no-cache"})}   # Function URL streaming
```

Streaming needs `--invoke-mode RESPONSE_STREAM` on the Function URL or
`InvokeWithResponseStream`. Errors after the first chunk are reported via
trailers; validate input before returning the stream.

## Managed Instances

Set `PerExecutionEnvironmentMaxConcurrency`; Mayfly starts that many pollers.
Handlers run concurrently in separate processes. Lambda does not kill a handler
at the deadline there: check `Mayfly.Context.remaining_time_ms/1` in loops.
Memory must be >= 2048 MB.

## Plug and Phoenix (dep {:mayfly_plug, "~> 0.1"})

```elixir
defmodule MyApp.Lambda, do: use Mayfly.Plug.Handler, plug: {MyAppWeb.Endpoint, []}   # or plug: MyRouter
# streaming: true for a RESPONSE_STREAM Function URL; on_error: :propagate to surface rendered 500s as Lambda errors
```
Phoenix: `server: false`, no `http:` block, bandit only in dev/test, no DNSCluster, SECRET_KEY_BASE/PHX_HOST as env vars.
No LiveView/channels (WebSocket). Test: `mix lambda.invoke MyApp.Lambda '{}' --http --method GET --path /api/x`.

## Graceful shutdown

Attach the `mayfly-shutdown-<arch>` layer (external extension → Lambda sends SIGTERM) and register
hooks in `init/1`: `Mayfly.Shutdown.register(fn -> flush_metrics() end)`. Each hook gets 1 s; then
Logger is flushed and the VM halts. Without the layer Lambda never signals the runtime.

## AWS calls (dep {:mayfly_aws, "~> 0.2"})

`Mayfly.AWS.S3` (put/get/head/delete/list/presign), `Mayfly.AWS.SQS` (send/receive/delete),
`Mayfly.AWS.SNS.publish/3`, `Mayfly.AWS.SSM.get_parameters_by_path!/2` and
`Mayfly.AWS.SecretsManager.get_secret_json/2` (fetch in `init/1`). Errors are `{:error, {code, msg}}`.

## Platform telemetry (billed duration, max memory)

Set `MAYFLY_EXTENSION=1` on the function (needs `{:telemetry, "~> 1.0"}`); then
`Mayfly.Metrics.attach_platform_metrics("MyApp")` in `init/1` publishes Lambda's own
Duration/BilledDuration/MaxMemoryUsed/InitDuration as EMF, or attach to
`[:mayfly, :platform, :report]` yourself (measurements `duration_ms`, `billed_duration_ms`,
`max_memory_used_mb`, `init_duration_ms`; metadata `request_id`). Arrives after the invocation.

## Metrics and idempotency

```elixir
Mayfly.Metrics.count("MyApp", "OrdersPlaced", 1, properties: %{"orderId" => id})   # EMF line → CloudWatch metric
Mayfly.Metrics.timing("MyApp", "DbLatency", ms)
def init(_), do: (Mayfly.Metrics.attach_invocation_metrics("MyApp"); {:ok, nil})  # Duration/Errors/ColdStart

# exactly-once (dep {:mayfly_aws, "~> 0.1"}, DynamoDB table with pk id + TTL expires_at)
case Mayfly.Idempotency.run(event, fn -> do_work(event) end, key_fun: & &1["orderId"], context: ctx) do
  {:ok, r} -> ...; {:ok, r, :replayed} -> ...; {:error, :in_progress} -> ...
end
```

## Configuration and observability

- `config/runtime.exs` works (bootstrap sets `RELEASE_TMP=/tmp`).
- JSON logs: set the function log format to JSON; `requestId`/`tenantId`
  appear automatically. `LOGLEVEL` or `AWS_LAMBDA_LOG_LEVEL` sets the level.
- `:telemetry` events: `[:mayfly, :init, :stop]`, `[:mayfly, :invocation, :start | :stop]`,
  `[:mayfly, :poll, :error]` (optional dep).
- `_X_AMZN_TRACE_ID` is exported per invocation for X-Ray.
