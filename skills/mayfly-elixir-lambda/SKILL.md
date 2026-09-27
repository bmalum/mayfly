---
name: mayfly-elixir-lambda
description: Build, test and deploy AWS Lambda functions written in Elixir with the Mayfly runtime. Use when a user wants Elixir on Lambda, mentions Mayfly, `use Mayfly.Handler`, `mix lambda.invoke`, `mix lambda.doctor`, the mayfly-erlang layer, `provided.al2023` with Elixir, Lambda response streaming from Elixir, or asks how to package a Mix release as lambda.zip.
license: MIT
metadata:
  version: "1.0.0-rc.1"
  docs: https://elixir-aws-lambda.dev/docs/llms.txt
  source: https://github.com/bmalum/mayfly
---

# Mayfly: Elixir on AWS Lambda

Mayfly is a Lambda custom runtime for Elixir. A Lambda function is a module
that implements the `Mayfly.Handler` behaviour; `mix release` produces the
deployment zip; the Erlang runtime comes from a Lambda layer (or is bundled).

Facts an agent must not get wrong:

- Elixir >= 1.18, OTP >= 27. Uses the built-in `JSON` module, not Jason.
- The Lambda **Handler** setting is the module name (`MyApp.Handler`), not
  `Module.function`. Legacy `Module.function` still resolves.
- `handle/3` returns `{:ok, result}` or `{:error, reason}`. Anything else is a
  `Runtime.InvalidResponse` error. `result` must be JSON-encodable or a
  `%Mayfly.Response{}`.
- Nothing starts in `mix test` or `iex`: the runtime only runs when the
  generated `bootstrap` calls `Mayfly.Boot.main/0`.
- With `layer: true` the build toolchain's OTP must equal the layer's OTP
  version exactly (e.g. 27.3.4.18). `mix lambda.doctor --layer ARN` verifies.
- Function URL / API Gateway events arrive wrapped: the JSON body is the
  string `event["body"]`. Test that shape with `mix lambda.invoke --http`.

## Workflow

1. **Add the dependency and a release** to `mix.exs` (function captures, not
   a call, so `mix deps.get` works before Mayfly is compiled):

   ```elixir
   deps: [{:mayfly, "~> 1.0.0-rc"}],
   releases: [
     lambda: [
       steps: [&Mayfly.Release.prepare/1, :assemble, &Mayfly.Release.bootstrap/1, &Mayfly.Release.zip/1],
       mayfly: [handler: MyApp.Handler, layer: true]
     ]
   ]
   ```

2. **Write the handler** (see `references/handler-patterns.md`):

   ```elixir
   defmodule MyApp.Handler do
     use Mayfly.Handler

     @impl true
     def init(_opts), do: {:ok, %{table: System.fetch_env!("TABLE_NAME")}}

     @impl true
     def handle(event, %Mayfly.Context{} = ctx, state) do
       {:ok, %{hello: event["name"], request_id: ctx.request_id, table: state.table}}
     end
   end
   ```

3. **Test locally, before any deploy.**

   ```bash
   mix lambda.invoke MyApp.Handler '{"name":"x"}'          # exact Lambda semantics, in-process emulator
   mix lambda.invoke MyApp.Handler event.json --http --path /items
   mix lambda.doctor                                       # release config, handler init/1, OTP vs layer
   ```

   In ExUnit use `Mayfly.LocalRuntime` (see `references/testing.md`).

4. **Build.** `MIX_ENV=prod mix release lambda` writes
   `_build/prod/rel/lambda/lambda.zip`. Without `layer: true`, build inside
   Amazon Linux 2023 instead: `mix lambda.build --docker --arch arm64`.

5. **Deploy** with runtime `provided.al2023`, architecture matching the layer,
   handler = module name, layer `mayfly-erlang-<otp>-<arch>` (ARNs:
   https://github.com/bmalum/mayfly/releases/tag/layers). IaC snippets for
   SAM/CDK/Terraform: https://elixir-aws-lambda.dev/docs/deployment.md.

## Diagnosing failures

| Symptom | Meaning | Fix |
|---|---|---|
| `Runtime.NoSuchHandler` at init | Handler setting is not a module in the release or lacks `use Mayfly.Handler` | check module name / `mix lambda.doctor` |
| `Runtime.InitError` | `init/1` returned `{:error, _}` or raised | message and stack trace are in the payload |
| `Runtime.InvalidResponse` | bad return shape or non-JSON value (tuples, structs without `JSON.Encoder`) | wrap in `{:ok, _}`, convert to maps |
| `Mayfly: no Erlang runtime at /opt/erlang` | no layer / wrong architecture | attach the layer for that arch |
| `release was built for ERTS X but the layer provides Y` | OTP mismatch | `mise use erlang@<layer otp>` or matching layer |
| `Mayfly.Context.remaining_time_ms/1` hits 0 on Managed Instances | Lambda does not kill the handler there | check remaining time in loops |

## Reference material

- `references/handler-patterns.md` – event shapes, errors, streaming, Managed Instances, config.
- `references/testing.md` – `Mayfly.LocalRuntime` in ExUnit, `mix lambda.invoke`.
- Full docs, agent-friendly index: https://elixir-aws-lambda.dev/docs/llms.txt
  (every page also exists as `.md`, e.g. `.../docs/streaming.md`).
- Source: https://github.com/bmalum/mayfly
