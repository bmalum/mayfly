# Testing Mayfly handlers

## Unit tests: call the callback directly

```elixir
test "greets" do
  ctx = %Mayfly.Context{request_id: "t-1"}
  {:ok, state} = MyApp.Handler.init([])
  assert {:ok, %{hello: "x"}} = MyApp.Handler.handle(%{"name" => "x"}, ctx, state)
end
```

## Integration tests: the real runtime against the emulator

`Mayfly.LocalRuntime` is an in-process Lambda Runtime API. It exercises
handler resolution, `init/1`, JSON decoding, error formatting and streaming
exactly like Lambda.

```elixir
defmodule MyApp.HandlerIntegrationTest do
  use ExUnit.Case

  setup do
    {:ok, rt} = Mayfly.LocalRuntime.start_link()
    {:ok, _sup} = Mayfly.start_link(handler: "MyApp.Handler", runtime_api: Mayfly.LocalRuntime.address(rt), name: nil)
    %{rt: rt}
  end

  test "success", %{rt: rt} do
    assert {:ok, %{status: 200, body: body}} = Mayfly.LocalRuntime.invoke(rt, %{"name" => "x"})
    assert %{"hello" => "x"} = JSON.decode!(body)
  end

  test "errors carry type, message and stack trace", %{rt: rt} do
    assert {:error, %{"errorType" => "ArgumentError", "stackTrace" => [_ | _]}} =
             Mayfly.LocalRuntime.invoke(rt, %{"mode" => "boom"})
  end

  test "streaming", %{rt: rt} do
    {:ok, %{body: body, headers: headers, trailers: %{}}} = Mayfly.LocalRuntime.invoke(rt, %{"mode" => "stream"})
    assert {"lambda-runtime-function-response-mode", "streaming"} in headers
  end
end
```

Extra invocation headers (e.g. tenant id):
`Mayfly.LocalRuntime.invoke(rt, event, headers: [{"Lambda-Runtime-Aws-Tenant-Id", "blue"}])`.

## Command line

```bash
mix lambda.invoke MyApp.Handler '{"a":1}'                 # exit 1 on error, prints the error payload
mix lambda.invoke MyApp.Handler event.json --http --method POST --path /items
echo '{"a":1}' | mix lambda.invoke MyApp.Handler -
mix lambda.doctor --layer arn:aws:lambda:eu-central-1:123:layer:mayfly-erlang-27-arm64:1
```

## Faithful emulation

For timeouts and cold-start behaviour run the built zip with
[aws-lambda-rie](https://github.com/aws/aws-lambda-runtime-interface-emulator)
in an `amazonlinux:2023` container with the layer unpacked to `/opt`.
