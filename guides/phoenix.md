# Plug and Phoenix on Lambda

"Can I run Phoenix on Lambda?" – the HTTP/API part, yes: one adapter, no HTTP
server. The companion package [`mayfly_plug`](https://github.com/bmalum/mayfly_plug)
turns API Gateway (v1/v2), Function URL and ALB events into `%Plug.Conn{}`s,
runs your router or endpoint, and returns the proxy response. LiveView and
channels need a WebSocket and stay out of scope.

```elixir
# mix.exs
deps: [{:mayfly, "~> 1.0.0-rc"}, {:mayfly_plug, "~> 0.1"}, {:phoenix, "~> 1.8"}, ...]

releases: [
  lambda: [
    steps: [&Mayfly.Release.prepare/1, :assemble, &Mayfly.Release.bootstrap/1, &Mayfly.Release.zip/1],
    mayfly: [handler: MyApp.Lambda, layer: true]
  ]
]
```

```elixir
defmodule MyApp.Lambda do
  use Mayfly.Plug.Handler, plug: {MyAppWeb.Endpoint, []}
end
```

That is the whole integration. A plain `Plug.Router` works the same way with
`plug: MyApp.Router`.

## Phoenix configuration

Generate the app without the parts that assume a server:

```bash
mix phx.new my_app --no-html --no-assets --no-ecto --no-live --no-mailer --no-dashboard
```

Then:

- **No server.** In `config/runtime.exs` set `server: false` for the endpoint
  and drop the `http:` block (Lambda never opens a port). Keep
  `url: [host: System.get_env("PHX_HOST"), port: 443, scheme: "https"]` so
  generated URLs are right. Move `{:bandit, ...}` to `only: [:dev, :test]`; it is
  not needed in the release.
- **Remove `DNSCluster`** from the supervision tree and the `dns_cluster` dep;
  there is no cluster.
- **`SECRET_KEY_BASE`** and `PHX_HOST` become Lambda environment variables.
  The application (Endpoint, PubSub, Telemetry) starts normally when
  `Mayfly.Boot` boots the release; your `init/1` runs after that.
- **Logging**: Phoenix's `Plug.Telemetry` log lines go through
  `Mayfly.LogFormatter` and show up in CloudWatch as JSON with the Lambda
  `requestId` when the function's log format is JSON.

What works: controllers, JSON views, pipelines and plugs, `Plug.Parsers`,
sessions in signed/encrypted cookies (`Plug.Session` with the `:cookie`
store), `Plug.Static` for files in `priv/static` (prefer S3/CloudFront for
assets), `Phoenix.PubSub` within one execution environment.

What does not: LiveView, channels and anything else that needs a WebSocket or
a long-lived connection; `Phoenix.PubSub` across instances; the live dashboard.

Ecto: start the Repo as usual, `pool_size: 1` or `2` (one invocation at a time
per environment; more on Managed Instances), and use RDS Proxy or Aurora DSQL
so thousands of environments do not open thousands of connections.

## Streaming

A second handler module with `streaming: true` serves `send_chunked`/`chunk`
responses through Lambda response streaming:

```elixir
defmodule MyApp.StreamingLambda do
  use Mayfly.Plug.Handler, plug: {MyAppWeb.Endpoint, []}, streaming: true
end
```

Deploy it as its own function (same zip, different handler) behind a Function
URL in `RESPONSE_STREAM` mode. Every chunk is sent as it is produced; plain
routes still work through that function. Buffered functions concatenate chunks
into one response.

## Errors

Phoenix renders a 500 through `Phoenix.Endpoint.RenderErrors` and re-raises.
`mayfly_plug` returns the rendered 500 to the client and logs the exception
(what Bandit does), so API Gateway shows your error JSON instead of a generic
502. Pass `on_error: :propagate` if you prefer Lambda to record a function
error. Exceptions raised before any response was sent always propagate.

## Measured

Phoenix 1.8.15 JSON API, Erlang layer, arm64, 1024 MB, eu-central-1:

| | |
|---|---|
| zip (BEAM files only) | 2.8 MB |
| `Init Duration` (cold start) | 586 ms / 739 ms |
| warm `GET /api/hello` | 3–10 ms function time, ~100–180 ms end to end via Function URL |
| memory | 94 MB |
| streamed route, 4 chunks 300 ms apart | chunks arrived at +1.61 s (cold), +1.91 s, +2.21 s, +2.52 s |

## Local testing

```bash
mix lambda.invoke MyApp.Lambda '{}' --http --method GET --path /api/hello
mix lambda.invoke MyApp.Lambda '{"name":"Ada"}' --http --path /api/users     # JSON body
mix lambda.invoke MyApp.StreamingLambda '{}' --http --method GET --path /api/stream --raw
```

`mix test` in your Phoenix app is untouched: `Phoenix.ConnTest` keeps using
`Plug.Test`; the Lambda adapter is only used inside the function.
