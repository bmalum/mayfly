# Operations

Running Mayfly functions in production: what to alarm on, how to read the
logs, what it costs, how to size Managed Instances, and what to do when
something is wrong. Everything here uses only what the runtime already emits;
nothing needs an agent or a vendor.

## What the runtime emits

| Signal | Where | Enabled by |
|---|---|---|
| Lambda's own metrics (`Invocations`, `Errors`, `Duration`, `Throttles`, `ConcurrentExecutions`) | CloudWatch `AWS/Lambda` | always |
| JSON log lines with `requestId`, `tenantId`, `level`, `message`, your metadata | CloudWatch Logs | function log format `JSON` (see [observability](observability.md)) |
| `platform.*` records (`initDurationMs`, `billedDurationMs`, `maxMemoryUsedMB`, timeouts) | CloudWatch Logs, same group | always (JSON format) |
| EMF metrics from `Mayfly.Metrics` (`Duration`, `Errors`, `ColdStart` per invocation; your own) | CloudWatch, your namespace | `attach_invocation_metrics/1`, `count/4`, … |
| Billed duration / max memory as EMF | CloudWatch, your namespace | `MAYFLY_EXTENSION=1` + `attach_platform_metrics/1` |
| `:telemetry` events | in-process | `{:telemetry, ...}` dependency |
| Shutdown hooks | your code | `mayfly-shutdown` layer |

## Alarms

Start with four alarms per function. Values are starting points; tune after a
week of traffic.

```bash
FN=my-fn; TOPIC=arn:aws:sns:eu-central-1:123456789012:alerts

# 1. Error rate > 1 % over 5 minutes (math expression on Lambda's own metrics)
aws cloudwatch put-metric-alarm --alarm-name "$FN-error-rate" --alarm-actions $TOPIC \
  --evaluation-periods 2 --datapoints-to-alarm 2 --threshold 1 --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --metrics '[
    {"Id":"errors","MetricStat":{"Metric":{"Namespace":"AWS/Lambda","MetricName":"Errors","Dimensions":[{"Name":"FunctionName","Value":"'$FN'"}]},"Period":300,"Stat":"Sum"},"ReturnData":false},
    {"Id":"invocations","MetricStat":{"Metric":{"Namespace":"AWS/Lambda","MetricName":"Invocations","Dimensions":[{"Name":"FunctionName","Value":"'$FN'"}]},"Period":300,"Stat":"Sum"},"ReturnData":false},
    {"Id":"rate","Expression":"100 * errors / MAX([invocations, 1])","Label":"error %"}]'

# 2. p99 duration above 80 % of the timeout (timeout 30 s -> 24 s)
aws cloudwatch put-metric-alarm --alarm-name "$FN-p99-duration" --alarm-actions $TOPIC \
  --namespace AWS/Lambda --metric-name Duration --dimensions Name=FunctionName,Value=$FN \
  --extended-statistic p99 --period 300 --evaluation-periods 3 --threshold 24000 \
  --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching

# 3. Throttles (any)
aws cloudwatch put-metric-alarm --alarm-name "$FN-throttles" --alarm-actions $TOPIC \
  --namespace AWS/Lambda --metric-name Throttles --dimensions Name=FunctionName,Value=$FN \
  --statistic Sum --period 60 --evaluation-periods 1 --threshold 0 --comparison-operator GreaterThanThreshold

# 4. Cold starts above 5 % of invocations (EMF from attach_invocation_metrics("MyApp"))
aws cloudwatch put-metric-alarm --alarm-name "$FN-cold-starts" --alarm-actions $TOPIC \
  --evaluation-periods 3 --threshold 5 --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching \
  --metrics '[
    {"Id":"cold","MetricStat":{"Metric":{"Namespace":"MyApp","MetricName":"ColdStart","Dimensions":[{"Name":"FunctionName","Value":"'$FN'"}]},"Period":300,"Stat":"Sum"},"ReturnData":false},
    {"Id":"all","MetricStat":{"Metric":{"Namespace":"MyApp","MetricName":"Duration","Dimensions":[{"Name":"FunctionName","Value":"'$FN'"}]},"Period":300,"Stat":"SampleCount"},"ReturnData":false},
    {"Id":"pct","Expression":"100 * cold / MAX([all, 1])","Label":"cold start %"}]'
```

Worth adding when they apply:

- **Memory headroom**: `MaxMemoryUsed` (EMF via `attach_platform_metrics/1`)
  `Maximum` above 85 % of the configured size. Lambda does not expose this as
  a metric itself; Mayfly's extension does.
- **Init errors**: a Logs metric filter on `{ $.type = "platform.initReport" && $.record.status = "error" }`;
  a function that fails in `init/1` never produces an `Errors` datapoint for the
  handler, so the error-rate alarm stays quiet.
- **Streaming**: `Duration` is wall time until the last chunk; alarm on your own
  `timing/4` metric for the part you control.
- **Dead-letter / failure destinations**: for async invokes, configure
  `--dead-letter-config` or an on-failure destination and alarm on the queue
  depth; Lambda retries twice and then drops the event.

## Reading the logs

With the function's log format set to JSON every line is an object, so Logs
Insights queries can filter on fields instead of regexes.

```sql
-- Errors with their stack traces, newest first
fields @timestamp, requestId, message
| filter level = "ERROR"
| sort @timestamp desc
| limit 50

-- Everything one invocation logged (yours + the platform records)
fields @timestamp, level, message, type, record.status
| filter requestId = "8f4c4018-c0a5-42dc-8c20-7ba4619311f0" or record.requestId = "8f4c4018-c0a5-42dc-8c20-7ba4619311f0"
| sort @timestamp asc

-- Cold starts: init duration distribution
filter type = "platform.initReport" and record.status = "success"
| stats count(), avg(record.metrics.durationMs), pct(record.metrics.durationMs, 50), pct(record.metrics.durationMs, 95) by bin(1h)

-- Billed duration and memory by hour (from platform.report)
filter type = "platform.report"
| stats sum(record.metrics.billedDurationMs) / 1000 as billed_seconds,
        max(record.metrics.maxMemoryUsedMB) as max_mb,
        count() as invocations by bin(1h)

-- Timeouts and runtime failures (the ones your handler never saw)
filter type = "platform.report" and record.status != "success"
| fields @timestamp, record.requestId, record.status, record.errorType

-- Per-tenant volume (tenantId is set from the Lambda-Runtime-Aws-Tenant-Id header)
stats count() by tenantId
| sort count() desc

-- Slow invocations with what they logged last
filter type = "platform.report" and record.metrics.durationMs > 5000
| fields record.requestId as rid, record.metrics.durationMs
```

Field names: Mayfly writes `requestId`, `tenantId`, `level`, `message`,
`timestamp` plus every `Logger.metadata` key; Lambda's records have `type`
and `record.*`. Your own metadata (`Logger.info("x", order_id: 1)`) becomes
`order_id`.

## Cost

Lambda bills GB-seconds (duration × memory) plus requests; the Erlang layer,
EMF metrics and JSON logs change the picture only through log volume.

Measured on arm64 (see [deployment](deployment.md) for the raw numbers):

| | Typical |
|---|---|
| Cold start (`initDurationMs`) | 450–600 ms at 512 MB; billed as part of the first invocation |
| Warm invocation, trivial handler | 2–10 ms, billed 1 ms granularity |
| Memory used, idle runtime | ~85 MB (so 128 MB works for small handlers; 512 MB is the sane default for CPU) |
| Phoenix JSON API | 0.6–0.75 s cold, 3–10 ms warm, ~95 MB |

Rules of thumb:

- A function doing 1 M invocations/month at 10 ms × 512 MB costs about
  **$0.20 + $0.08 = $0.28**; 1 M cold starts at 550 ms would add ~$4.60. Cold
  starts, not warm duration, dominate the bill for low-traffic functions;
  for high-traffic ones memory size × duration does.
- arm64 is ~20 % cheaper per GB-second than x86_64 and Mayfly's cold starts
  are equal or better there. Default to arm64.
- CloudWatch Logs ingestion ($0.50/GB) is the hidden cost of chatty JSON
  logging. One 300-byte line per invocation at 1 M/month is 0.3 GB ($0.15);
  `LOGLEVEL=warning` in production plus an `Errors` alarm is cheaper than
  info-level everything. Set a retention (`--log-retention` in the IaC
  templates defaults to 14 days).
- EMF metrics cost per metric per month (first 10 000 free, then $0.30 each
  after tiers), not per datapoint; a `Duration` metric with the `FunctionName`
  dimension is one metric. High-cardinality dimensions (`requestId`, user ids)
  are a cost bug: use properties, not dimensions.
- The public Erlang layers cost you nothing; layer storage counts against the
  publisher's quota, not yours.
- Managed Instances bill the EC2 instances, not GB-seconds: a `m7g.large`
  (~$0.08/h on-demand) running 8 concurrent invocations replaces up to 8 ×
  2 GB of classic Lambda. It pays off above roughly 30–40 % sustained
  utilisation of that capacity; below, classic Lambda is cheaper.

## Sizing Managed Instances

Mayfly starts one poller per `AWS_LAMBDA_MAX_CONCURRENCY` slot and the VM
keeps all vCPUs as schedulers, so a Managed Instances environment is a normal
multi-core BEAM node serving `PerExecutionEnvironmentMaxConcurrency` requests
in parallel.

- **Memory**: `ExecutionEnvironmentMemoryGiBPerVCpu` × vCPUs is the
  environment's memory. The runtime itself needs ~90 MB; budget per-invocation
  working set × concurrency on top. 2 GiB/vCPU is a good start for API work.
- **Concurrency per environment**: start at vCPUs × 2 for I/O-bound handlers
  (the BEAM parks processes waiting on sockets cheaply) and vCPUs × 1 for
  CPU-bound ones. Verified: 8 concurrent invocations on one m7g.large
  (2 vCPU) finished in 0.13 s wall time.
- **Instance type**: `m7g.large` is the smallest sensible arm64 choice;
  `MaxVCpuCount` on the capacity provider caps spend. `c7g` for CPU-heavy,
  `r7g` for cache-heavy handlers.
- **Deadlines**: Managed Instances do not kill a handler at the function
  timeout. Long loops must check `Mayfly.Context.remaining_time_ms/1` and
  stop themselves, or they keep a slot busy forever.
- **State**: `init/1` state is shared read-only across the pollers. Anything
  mutable belongs in a named process (`Agent`, `GenServer`) started from
  `init/1`; it is one BEAM node, so OTP works as usual, including ETS caches
  shared by all concurrent invocations.
- **Extensions**: internal extensions cannot register for `INVOKE` on
  Managed Instances; `Mayfly.Extension` still receives `platform.report`
  through the Telemetry API, which is what `attach_platform_metrics/1` uses.

## Runbook

**Error rate alarm fired.** Logs Insights: `filter level = "ERROR"` and group
by `message` prefix to see whether it is one exception type. Mayfly's error
lines include `errorType` and the first stack frame; if the type is
`Runtime.InvalidResponse` the handler returned something unencodable, if
`HandlerError` it returned `{:error, _}` deliberately.

**Latency alarm fired, errors flat.** Check cold-start percentage (EMF
`ColdStart`) first: a deploy or a traffic spike creates new environments.
Then `platform.report` durations vs your own `timing/4` metrics to see whether
the time is yours or a downstream call's. If it is yours and CPU-bound,
increase memory (more vCPU).

**Function times out.** `platform.report` with `record.status = "timeout"`
and `record.metrics.durationMs ≈ timeout`. There is no handler log for the
end because the environment was killed. If the handler blocks on a downstream
call, set socket timeouts below the function timeout so the error is yours
and carries context. On Managed Instances a timeout does not kill the handler
(see above).

**Init error / `Runtime.InitError`.** The function never served a request;
`platform.initReport` has `status: error`. The payload posted to
`/runtime/init/error` is in the logs as an ERROR line with the exception from
`init/1`. Common causes: a missing environment variable read with
`System.fetch_env!/1`, a dependency's application failing to start (check
`included_applications` / `extra_applications`), or the layer OTP mismatch
message from `bootstrap`.

**`Mayfly: release was built for ERTS X but the layer provides Y`.** Build
toolchain and layer disagree. `mix lambda.doctor` tells you which; fix the
`.tool-versions` or the layer ARN in the IaC (doctor checks both).

**Retries and duplicates.** Async invokes retry twice; SQS redelivers after
the visibility timeout; EventBridge retries for up to 24 h. If an operation
must not run twice, wrap it in `Mayfly.Idempotency.run/3` (companion package
`mayfly_aws`) with a business key; see the [idempotency guide](idempotency.md).

**Lost log lines at shutdown.** Without the `mayfly-shutdown` layer Lambda
freezes and discards the environment silently; buffered log handlers lose
their tail. Attach the layer and register `Mayfly.Shutdown` hooks for anything
that must flush (see [observability](observability.md)).

**Rolling back.** Functions are versioned; alias `live` → version N. `aws
lambda update-alias --name live --function-version N-1` is the rollback;
with SAM/CDK the stack rollback does the same. Layers are immutable, so a
rollback of the function also rolls back the layer it pointed to.

**Deploying a new OTP major.** Switch the layer ARN *and* the toolchain
together (`mise use erlang@…`, `--otp` in the IaC, or `mix lambda.new --otp`).
Build, `mix lambda.doctor`, deploy to a new version, shift the alias. The
runtime verifies the match at boot, so a half-switch fails loudly rather than
running a mismatched ERTS.
