# Migrating from 0.x

## Summary of breaking changes

| 0.x | 1.0 |
|---|---|
| Elixir ≥ 1.15, Jason dependency | Elixir ≥ 1.18, built-in `JSON`, no runtime deps |
| `_HANDLER=Elixir.MyApp.Handler.handle` (MFA) | `_HANDLER=MyApp.Handler` (module with `use Mayfly.Handler`); MFA still accepted |
| `def handle(event)` returns `{:ok, _}` | `def handle(event, ctx, state)`; bare return values are errors |
| `mix lambda.build --zip` with `MIX_ENV=lambda` | `mix release lambda` with the `Mayfly.Release` steps; `mix lambda.build` only orchestrates Docker |
| `:mayfly` application auto-started the loop | Nothing starts implicitly; `bootstrap` runs `Mayfly.Boot.main/0` |
| `errorType: "Elixir.KeyError"`, `stackTrace: "…"` | `"KeyError"`, `stackTrace: [...]` |
| `{:error, "s"}` → `RuntimeError` | `HandlerError` |
| `Mayfly.Error`, `Mayfly.Runtime`, `Mayfly.Loop` | `Mayfly.ErrorPayload`, `Mayfly.RuntimeAPI`, `Mayfly.Poller` |

## Step by step

### 1. Toolchain

Elixir 1.18+ / OTP 27+. Remove `{:jason, ...}` if Mayfly was the only user;
replace `Jason.encode!/decode!` in your handlers with `JSON.encode!/decode!`.
(Jason keeps working for your own code if you keep it.)

### 2. Handler

Before:

```elixir
defmodule MyApp.Handler do
  def handle(event) do
    {:ok, %{ok: true}}
  end
end
```

After:

```elixir
defmodule MyApp.Handler do
  use Mayfly.Handler

  @impl true
  def handle(event, %Mayfly.Context{} = _ctx, _state) do
    {:ok, %{ok: true}}
  end
end
```

Set the Lambda Handler to `MyApp.Handler`. If you cannot change the handler
setting yet, `MyApp.Handler.handle` (arity 1 or 2) keeps working.

Move any one-time setup into `init/1` and read it from `state`.

### 3. Build

Before: `mix lambda.build --zip` (and a `config/lambda.exs` if you imported
config per env).

After:

```elixir
releases: [
  lambda: [steps: [&Mayfly.Release.prepare/1, :assemble, &Mayfly.Release.bootstrap/1, &Mayfly.Release.zip/1], mayfly: [handler: MyApp.Handler, layer: true]]
]
```

```bash
MIX_ENV=prod mix release lambda      # _build/prod/rel/lambda/lambda.zip
```

Delete `config/lambda.exs` if it only existed for Mayfly. If you bundled ERTS
via Docker before, keep doing so with `mix lambda.build --docker --arch …` and
drop `layer: true`.

### 4. Error handling in callers

If downstream code matched on `errorType`, update:

- `"Elixir.KeyError"` → `"KeyError"`
- `"RuntimeError"` for `{:error, "string"}` → `"HandlerError"`
- `"UnknownError"` → `"HandlerError"`
- `stackTrace` is now a list

Handlers that returned bare values (not `{:ok, _}`) were silently accepted in
0.x; they now fail with `Runtime.InvalidResponse`. Wrap them in `{:ok, _}`.

### 5. Local development

`mix test` / `iex -S mix` no longer start a polling loop. Use
`mix lambda.invoke MyApp.Handler event.json` to run a handler locally, or
`Mayfly.LocalRuntime` in ExUnit.

### 6. Optional

- Add `{:telemetry, "~> 1.0"}` for runtime events.
- Switch the function's log format to JSON for structured logs.
- Consider `layer: true` to drop Docker from your build.
