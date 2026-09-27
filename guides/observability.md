# Observability

## Structured logs

Enable JSON logging on the function (console → Configuration → Monitoring and
operations tools → Log format, or `LoggingConfig: {LogFormat: JSON}` in IaC).
Lambda then sets `AWS_LAMBDA_LOG_FORMAT=JSON` and `Mayfly.Boot` installs
`Mayfly.LogFormatter`, which emits one JSON object per line:

```json
{"timestamp":"2026-09-27T07:33:27.991Z","level":"ERROR","requestId":"7d3c…","tenantId":"blue",
 "traceId":"Root=1-…","message":"Invocation 7d3c… failed: ArgumentError: bad argument","poller":0}
```

CloudWatch Logs Insights understands these fields directly:

```
fields @timestamp, level, requestId, message
| filter level = "ERROR"
| sort @timestamp desc
```

`Logger.metadata/1` keys you set in your handler are included as top-level
fields. During an invocation Mayfly sets `request_id`, `tenant_id` and
`trace_id` for you.

### Log level

`AWS_LAMBDA_LOG_LEVEL` (set by the *Application log level* setting) or
`LOGLEVEL` (`debug | info | warning | error`) controls the Logger level.
Default is `info`.

### Plain text

Without JSON logging the default Elixir console formatter is used. Add
metadata to see request ids:

```elixir
# config/runtime.exs
config :logger, :default_formatter, metadata: [:request_id, :tenant_id]
```

## Telemetry

Add `{:telemetry, "~> 1.0"}` to your deps and Mayfly emits:

| Event | Measurements | Metadata |
|---|---|---|
| `[:mayfly, :init, :stop]` | `duration` | `handler`, `result` |
| `[:mayfly, :invocation, :start]` | `system_time` | `context` |
| `[:mayfly, :invocation, :stop]` | `duration` | `context`, `result`, `error_type` |
| `[:mayfly, :poll, :error]` | `backoff_ms` | `reason` |

Attach handlers in `init/1`:

```elixir
def init(_opts) do
  :telemetry.attach("my-app-invocations", [:mayfly, :invocation, :stop], &MyApp.Metrics.handle/4, nil)
  {:ok, nil}
end
```

Emit CloudWatch Embedded Metric Format lines from the handler to get metrics
without API calls:

```elixir
def handle([:mayfly, :invocation, :stop], %{duration: d}, %{result: r}, _) do
  IO.puts(JSON.encode!(%{
    "_aws" => %{"Timestamp" => System.system_time(:millisecond),
                "CloudWatchMetrics" => [%{"Namespace" => "MyApp", "Dimensions" => [["Result"]],
                                          "Metrics" => [%{"Name" => "Duration", "Unit" => "Milliseconds"}]}]},
    "Result" => to_string(r),
    "Duration" => System.convert_time_unit(d, :native, :millisecond)
  }))
end
```

## X-Ray

Mayfly exports `_X_AMZN_TRACE_ID` from the invocation's trace header before
calling the handler, so X-Ray-aware libraries pick up the trace, and sends an
X-Ray cause document with every error report
(`Lambda-Runtime-Function-Xray-Error-Cause`). Enable active tracing on the
function to see segments.

## Debugging in production

- `Mayfly.Context.remaining_time_ms/1` – log it when approaching the deadline.
- Errors carry the Elixir stack trace (handler frames only) in `stackTrace`;
  the console and `aws lambda invoke` show it.
- `request_id` in the error payload matches the `RequestId` in Lambda's
  `REPORT` line, so a single Insights query joins runtime and function logs.
- Cold start vs. warm: `[:mayfly, :init, :stop]` fires once per execution
  environment; count it to measure cold starts.
