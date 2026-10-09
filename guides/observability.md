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

## Metrics (CloudWatch Embedded Metric Format)

`Mayfly.Metrics` writes metrics as EMF JSON lines on stdout; CloudWatch Logs
turns them into metrics with no API calls, no SDK and no extra permissions:

```elixir
Mayfly.Metrics.count("MyApp", "OrdersPlaced", 1, properties: %{"orderId" => id})
Mayfly.Metrics.timing("MyApp", "DbLatency", ms, dimensions: %{"Table" => "orders"})
Mayfly.Metrics.emit("MyApp", %{"CartValue" => {129.5, "None"}, "Items" => 3}, dimensions: %{"Tenant" => t})
```

Per-invocation `Duration`, `Errors` and `ColdStart` (dimension `FunctionName`)
come for free when `:telemetry` is a dependency:

```elixir
def init(_opts) do
  Mayfly.Metrics.attach_invocation_metrics("MyApp")
  {:ok, nil}
end
```

Query with `aws cloudwatch get-metric-statistics --namespace MyApp …` about a
minute after the invocation. EMF lines bypass `Logger` on purpose: CloudWatch
parses them from the raw line, which must be a standalone JSON object.

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

## Platform telemetry (Lambda Telemetry API)

Lambda knows things about an invocation that the function cannot measure
itself: the billed duration, the memory high-water mark, the init duration,
whether the runtime timed out. The Telemetry API hands these to *extensions*.
Mayfly ships an internal one, off by default:

```bash
MAYFLY_EXTENSION=1          # Lambda environment variable
# or: config :mayfly, extension: true
```

At cold start `Mayfly.Extension` registers with the Extensions API (before the
first `/next` poll, as Lambda requires), opens a small HTTP listener on
`sandbox.localdomain` and subscribes to `platform` telemetry. Every record then
becomes a `:telemetry` event `[:mayfly, :platform, type]` with the record's
`metrics` as measurements:

```elixir
:telemetry.attach("billing", [:mayfly, :platform, :report], fn _event, m, meta, _ ->
  Logger.info("request #{meta.request_id}: #{m.duration_ms} ms, billed #{m.billed_duration_ms} ms, #{m.max_memory_used_mb} MB")
end, nil)
```

`type` is the record type without the `platform.` prefix, underscored:
`:init_start`, `:init_runtime_done`, `:init_report`, `:start`, `:runtime_done`,
`:report`, `:extension`, `:telemetry_subscription`, `:log_dropped`. Note that
`platform.report` for an invocation arrives *after* that invocation has
returned, so correlate by `request_id` rather than by the current invocation.

Pair it with `Mayfly.Metrics.attach_platform_metrics/1` to publish the numbers
as EMF metrics (`Duration`, `BilledDuration`, `MaxMemoryUsed`, `MemorySize`,
`InitDuration` on cold starts), dimension `FunctionName`:

```elixir
def init(_opts) do
  Mayfly.Metrics.attach_platform_metrics("MyApp")
  {:ok, nil}
end
```

Compared with `attach_invocation_metrics/1`, `Duration` is Lambda's own
measurement and `BilledDuration` is what you pay for. Each record is also
logged at `debug`; to see those lines set the function's
`ApplicationLogLevel` to `DEBUG` (Lambda's log filter applies before yours).

Limits: Lambda does not deliver `SHUTDOWN` to internal extensions
(registering for it fails with `ShutdownEventNotSupportedForInternalExtension`),
so there is no shutdown hook; that would require an external extension. Cost:
one registration and one subscription call at init; measured cold start
median 534 ms with the extension vs 527 ms without (arm64, 512 MB, 12/10
samples), within the run-to-run noise.

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
