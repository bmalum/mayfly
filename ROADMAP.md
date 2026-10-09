# Mayfly roadmap

What is done, what is being considered, and one proposal written out in full.
Dates are when a decision was taken, not promises. Open an issue to argue for
or against anything here.

## Shipped (1.0.0-rc.1)

- Runtime: `Mayfly.Handler` behaviour, `mix release` build with the Mayfly
  ERTS layers (OTP 27/28/29, 16 regions, arm64 + x86_64), bundled ERTS via
  Docker, container images (`mix lambda.build --image`).
- Events and responses: `Mayfly.Events` decoders (API Gateway v1/v2, Function
  URL, ALB, SQS, SNS, S3, EventBridge, Kinesis, DynamoDB Streams), buffered
  and streamed responses, Function URL preludes.
- Observability: JSON logs, EMF metrics, `:telemetry`, internal extension for
  the Telemetry API, X-Ray propagation.
- Shutdown: `Mayfly.Shutdown` + the `mayfly-shutdown` external extension layer
  (SIGTERM hooks and log flush on environment shutdown).
- Companions: `mayfly_plug` (Plug/Phoenix endpoints as handlers),
  `mayfly_aws` (Idempotency, DynamoDB, S3, SQS, SNS, SSM, Secrets Manager).
- Scaffolding: `mix lambda.new` with SAM/Terraform/CDK templates, catalog-
  rendered layer ARNs; `mix lambda.doctor`, `mix lambda.invoke`.
- Verified on real Lambda: every OTP major on both architectures, Managed
  Instances, response streaming, container images.

## Considered and not done

- **Elixir precompiled layer** (2026-10-09): measured 511 vs 543 ms median
  cold start, below the 50 ms bar for a second version axis. Numbers in
  `guides/layers.md`.
- **`mix lambda.build --deploy`**: deployment belongs to IaC; `mix lambda.new`
  gives you SAM/Terraform/CDK instead.
- **SHUTDOWN for the internal extension**: Lambda does not deliver it to
  internal extensions; solved with the external `mayfly-shutdown` layer.

## Next

1. **Publish to Hex** (`mayfly`, then `mayfly_plug`, `mayfly_aws`); cut 1.0.0
   after the rc period.
2. **API Gateway HTTP API template** for `mix lambda.new` (today: Function URL).
3. **`mix lambda.doctor` reads the IaC files** and checks the layer ARN against
   the toolchain OTP.
4. **Durable Functions** – see the PR-FAQ below. Decision pending feedback.

---

## PR-FAQ: `mayfly_durable` – durable workflows for Elixir on Lambda

*Working backwards document. Nothing here exists yet.*

### Press release

**Elixir developers can now write multi-step, long-running workflows as plain
functions on AWS Lambda.** `mayfly_durable`, a companion package to Mayfly,
turns a handler into a durable workflow: each step's result is checkpointed to
DynamoDB, so a workflow that waits hours for a callback, retries a flaky API
for days, or fans out to a thousand sub-tasks survives Lambda's 15-minute
limit, cold starts and crashes. When the workflow resumes, completed steps are
replayed from the checkpoint instead of re-executed. There is no new service to
run and nothing to deploy besides a table: the orchestrator is your Lambda
function.

```elixir
defmodule Orders.Fulfil do
  use Mayfly.Durable.Workflow

  def run(%{"order_id" => id}, ctx) do
    payment = step(ctx, "charge", fn -> Payments.charge(id) end)
    :ok = step(ctx, "reserve", fn -> Stock.reserve(id) end)
    label = wait_for(ctx, "label-created", timeout: {:hours, 24})
    step(ctx, "notify", fn -> Mail.shipped(id, label) end)
    {:ok, %{payment: payment.id}}
  end
end
```

Each `step/3` runs the function once and stores its return value; a second
execution of the same workflow instance returns the stored value without
calling the function. `wait_for/3` checkpoints and *ends the invocation*; the
workflow resumes when an external signal arrives (an HTTP call, an SQS message,
a timer) and the orchestrator is re-invoked with the same instance id.

### FAQ

**Why not Step Functions?** You should use Step Functions when the workflow
is the product: visual, auditable, operated by people who do not read Elixir.
`mayfly_durable` is for the other case, where the orchestration is a dozen
lines of business logic that happen to span time, and expressing it in ASL
JSON with a Lambda per state is the heavier tool. The two interoperate: a
durable workflow step can start a Step Functions execution and `wait_for` its
callback.

**How is this different from AWS Lambda Durable Functions?** AWS's durable
functions (where available) are a managed feature with SDKs for a fixed set
of runtimes; Elixir is not one of them. `mayfly_durable` gives Elixir the same
programming model on the existing `provided.al2023` runtime with user-owned
state. If AWS ships Elixir support, this package should become an adapter.

**What is stored?** One DynamoDB item per workflow instance (`pk = instance
id`) holding the step log: `[{name, status, result_json, finished_at}]`, the
pending wait (if any) with its deadline, and the original input. Results are
JSON; large results should be put in S3 and referenced (same rule as
`Mayfly.Idempotency`). The item has a TTL after completion.

**What are the semantics?** Steps are *at-least-once*: a crash between
running a step and writing its checkpoint re-runs the step on resume. Step
functions must therefore be idempotent or wrapped in `Mayfly.Idempotency`
(same table works). Steps are *deterministic by name*: the orchestrator does
not record control flow, only named results, so `if` branches that depend on
step results are fine, but renaming a step mid-flight is a new step. Workflow
code may not block on time (`Process.sleep`) across invocations; it uses
`wait_for`/`sleep_until`, which end the invocation.

**How does resumption work?** The orchestrator function is invoked with
`%{"instance_id" => …}` (plus an optional signal payload). `Mayfly.Durable`
loads the item, runs `run/2` from the top, short-circuits completed steps,
and either finishes, or writes a new wait and returns `{:ok, :waiting}`.
Signals come in through whatever already invokes the function: a Function
URL (`POST /signal/:instance_id/:name`), an SQS message with the instance id,
or an EventBridge Scheduler one-time schedule created by `sleep_until/2`
(the package creates it with the function's own ARN as target).

**Fan-out?** `each(ctx, "items", items, fn item -> … end, concurrency: 50)`
invokes the same function asynchronously once per item with a child instance
id and `wait_for`s the children; results are collected in the parent's step
log. Children are ordinary workflow instances.

**Where does the Lambda timeout go?** Each invocation does as many steps as
fit before `Mayfly.Context.remaining_time_ms/1` drops below a margin, then
checkpoints and re-invokes itself asynchronously. A workflow can therefore
run for days; the longest *single step* must fit in one invocation.

**What does it cost?** DynamoDB reads/writes per step (on-demand: fractions
of a cent per thousand steps), one EventBridge Scheduler schedule per timed
wait, and Lambda invocations for each resume. No idle compute. A workflow
waiting a week costs one schedule.

**Failure handling?** A step that raises fails the workflow after `retries:`
attempts (exponential backoff via re-invocation, so retries do not consume
Lambda time). The failure is recorded; `on_failure/2` lets the workflow
compensate (saga style). Dead workflows are queryable from the table.

**Testing?** `Mayfly.Durable.Test` drives a workflow in-process against a
fake table: `run_until_waiting/2`, `signal/3`, `advance_time/2`, with the
step log inspectable. No AWS needed.

**Why a separate package?** It depends on `mayfly_aws` (DynamoDB,
Scheduler) and on `:telemetry`; the core must stay dependency-free. It also
imposes a programming model that most functions do not need.

**What would make us not build it?** Little demand for multi-step workflows
in Elixir-on-Lambda (most functions today are single-step event handlers), or
AWS shipping Elixir support for its managed durable functions. We will build
a prototype if three users describe a workflow they would run on it.

### Open questions

- Replay-by-name vs. replay-by-position: name is simpler to reason about;
  position (as in Temporal) allows loops without naming every iteration.
  Start with names plus an explicit `each`.
- Scheduler vs. SQS delay queues for timers: Scheduler supports arbitrary
  delays and one-time schedules; SQS caps delays at 15 minutes. Scheduler.
- Should `wait_for` support `Mayfly.Events.HTTP` natively so a Function URL
  can be the signal endpoint with zero code? Probably yes, behind an option.
