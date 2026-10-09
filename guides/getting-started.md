# Getting Started

## Prerequisites

- Elixir 1.18+ and OTP 27+
- An AWS account and the AWS CLI (for deployment)
- Docker only if you bundle ERTS instead of using the layer

## 1. Add Mayfly and a release

> **Shortcut:** `mix lambda.new hello --iac sam` (from any project that has
> `mayfly` in its deps, or a Mayfly checkout) generates everything in steps 1–3
> plus a SAM, Terraform or CDK definition; see the
> [deployment guide](deployment.md#infrastructure-as-code). The steps below
> show what it generates.

```elixir
# mix.exs
def project do
  [
    app: :hello,
    version: "0.1.0",
    elixir: "~> 1.18",
    deps: [{:mayfly, "~> 1.0.0-rc"}],
    releases: [
      lambda: [
        steps: [&Mayfly.Release.prepare/1, :assemble, &Mayfly.Release.bootstrap/1, &Mayfly.Release.zip/1],
        mayfly: [handler: Hello.Handler, layer: true]
      ]
    ]
  ]
end
```

`layer: true` means the zip will not contain ERTS; the Mayfly layer provides it.
Leave it out to bundle ERTS (then build with `mix lambda.build --docker`).

## 2. Write the handler

```elixir
# lib/hello/handler.ex
defmodule Hello.Handler do
  use Mayfly.Handler

  @impl true
  def handle(event, %Mayfly.Context{} = ctx, _state) do
    name = Map.get(event, "name", "World")

    {:ok,
     %{
       message: "Hello, #{name}!",
       request_id: ctx.request_id,
       remaining_ms: Mayfly.Context.remaining_time_ms(ctx)
     }}
  end
end
```

## 3. Try it locally

```bash
mix lambda.invoke Hello.Handler '{"name":"Elixir"}'
# %{"message" => "Hello, Elixir!", "remaining_ms" => 29998, "request_id" => "local-1-..."}
```

This runs the real runtime against an emulated Runtime API, so errors, the
context and JSON encoding behave exactly as in Lambda.

## 4. Build

```bash
MIX_ENV=prod mix release lambda
# * creating _build/prod/rel/lambda/bootstrap
# * creating _build/prod/rel/lambda/lambda.zip (2140 KiB)
```

## 5. Deploy

```bash
ARCH=arm64                                  # or x86_64 – must match the layer
LAYER=arn:aws:lambda:eu-central-1:ACCOUNT:layer:mayfly-erlang-27-3-4-$ARCH:1

aws lambda create-function \
  --function-name hello \
  --runtime provided.al2023 \
  --architectures $ARCH \
  --handler Hello.Handler \
  --layers $LAYER \
  --zip-file fileb://_build/prod/rel/lambda/lambda.zip \
  --role arn:aws:iam::ACCOUNT:role/lambda-execution-role \
  --timeout 30 --memory-size 512

aws lambda invoke --function-name hello \
  --cli-binary-format raw-in-base64-out \
  --payload '{"name":"Lambda"}' /dev/stdout
```

Your local OTP must be the layer's exact version (the `bootstrap` checks it);
`mise use erlang@27.3.4.18 elixir@1.18.4-otp-27` does it. Public layer ARNs are
listed in [layers.md](layers.md); to publish your own run
`layer/build.sh && layer/publish.sh --region eu-central-1`. Or skip the layer
and bundle ERTS with `mix lambda.build --docker --arch $ARCH` (docker or finch).

## 6. Iterate

```bash
MIX_ENV=prod mix release lambda --overwrite
aws lambda update-function-code --function-name hello \
  --zip-file fileb://_build/prod/rel/lambda/lambda.zip
```

## Handler patterns

```elixir
# state from init/1
def init(_opts), do: {:ok, %{client: MyApp.Client.new()}}
def handle(event, _ctx, %{client: client}), do: {:ok, MyApp.Client.call(client, event)}

# pattern matching on the event
def handle(%{"action" => "create"} = e, _ctx, _s), do: {:ok, create(e)}
def handle(%{"action" => "delete"} = e, _ctx, _s), do: {:ok, delete(e)}
def handle(_e, _ctx, _s), do: {:error, %{errorType: "BadRequest", errorMessage: "unknown action"}}

# Function URL / API Gateway: the payload arrives as event["body"] (a string)
def handle(%{"rawPath" => path, "body" => body}, _ctx, _s) do
  {:ok, %{statusCode: 200, headers: %{"content-type" => "application/json"},
          body: JSON.encode!(%{path: path, received: JSON.decode!(body || "{}")})}}
end
# try it: mix lambda.invoke Hello.Handler '{"a":1}' --http --path /items
```

Next: [Deployment](deployment.md), [Streaming](streaming.md), [Observability](observability.md).
