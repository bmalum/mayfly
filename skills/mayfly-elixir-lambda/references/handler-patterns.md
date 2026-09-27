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

## Event shapes

```elixir
# direct invoke / EventBridge / SQS: the JSON you sent
def handle(%{"Records" => records}, _ctx, _s), do: ...

# Function URL / API Gateway HTTP API: payload is wrapped
def handle(%{"requestContext" => %{"http" => %{"method" => m, "path" => p}}, "body" => body}, ctx, s) do
  {:ok, json} = JSON.decode(body || "{}")
  {:ok, %{statusCode: 200, headers: %{"content-type" => "application/json"},
          body: JSON.encode!(route(m, p, json))}}
end

# SQS partial batch response
def handle(%{"Records" => records}, _ctx, _s) do
  failures = for r <- records, {:error, _} <- [process(r)], do: %{itemIdentifier: r["messageId"]}
  {:ok, %{batchItemFailures: failures}}
end
```

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

## Configuration and observability

- `config/runtime.exs` works (bootstrap sets `RELEASE_TMP=/tmp`).
- JSON logs: set the function log format to JSON; `requestId`/`tenantId`
  appear automatically. `LOGLEVEL` or `AWS_LAMBDA_LOG_LEVEL` sets the level.
- `:telemetry` events: `[:mayfly, :init, :stop]`, `[:mayfly, :invocation, :start | :stop]`,
  `[:mayfly, :poll, :error]` (optional dep).
- `_X_AMZN_TRACE_ID` is exported per invocation for X-Ray.
