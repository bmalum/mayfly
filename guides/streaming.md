# Response streaming

Lambda can stream a response to the caller while your handler is still
producing it – useful for LLM token streams, large exports, or server-sent
events. Mayfly implements the custom-runtime streaming protocol
(`Lambda-Runtime-Function-Response-Mode: streaming`, chunked transfer encoding,
error trailers).

## Returning a stream

```elixir
defmodule MyApp.Stream do
  use Mayfly.Handler

  @impl true
  def handle(%{"prompt" => prompt}, _ctx, _state) do
    chunks =
      prompt
      |> MyApp.LLM.stream_tokens()               # any Enumerable of iodata
      |> Stream.map(&"data: #{&1}\n\n")

    {:ok,
     %Mayfly.Response{body: chunks, content_type: "text/event-stream"}
     |> Mayfly.Response.stream()}
  end
end
```

The enumerable is consumed lazily; each element is written as one HTTP chunk.
Empty elements are skipped.

## Function URLs: status and headers

When the function is behind a Function URL in `RESPONSE_STREAM` mode, Lambda
expects an HTTP "prelude" before the body. Add it with `Mayfly.Response.http/2`:

```elixir
{:ok,
 %Mayfly.Response{body: chunks, content_type: "text/event-stream"}
 |> Mayfly.Response.stream()
 |> Mayfly.Response.http(
   status: 200,
   headers: %{"cache-control" => "no-cache", "x-accel-buffering" => "no"},
   cookies: []
 )}
```

Mayfly sets `Content-Type: application/vnd.awslambda.http-integration-response`
and prepends the JSON prelude plus the eight-null-byte delimiter; Lambda strips
both before forwarding to the client. Without `http/2` the raw chunks are sent
as-is (correct for `InvokeWithResponseStream` callers).

## Errors while streaming

Before the first chunk, any error is reported through `/runtime/invocation/<id>/error`
as usual. Once streaming has started, the HTTP response is committed, so an
exception raised by the enumerable is reported via trailers:

```
Lambda-Runtime-Function-Error-Type: Function.RuntimeError
Lambda-Runtime-Function-Error-Body: <base64 error payload>
```

Lambda records the invocation as successful and forwards the error metadata
to the client (Function URLs close the connection; `InvokeWithResponseStream`
delivers an `InvokeComplete` event with `ErrorCode`/`ErrorDetails`). Validate
input and fail fast *before* returning the stream when you can.

## Invoking

```bash
# Function URL
aws lambda create-function-url-config --function-name stream \
  --auth-type NONE --invoke-mode RESPONSE_STREAM
curl -N https://<url-id>.lambda-url.eu-central-1.on.aws/

# SDK / CLI
aws lambda invoke-with-response-stream --function-name stream \
  --cli-binary-format raw-in-base64-out --payload '{"prompt":"hi"}' /dev/stdout
```

The Lambda console always shows a buffered result; that is expected.

## Backpressure

Each element of the enumerable is written to the Runtime API socket
synchronously, so a producer that is faster than the consumer simply blocks
inside the stream: no buffering, no unbounded memory. If Lambda stops reading
altogether, a single write may stall; `send_timeout` bounds that:

```elixir
%Mayfly.Response{body: chunks} |> Mayfly.Response.stream(send_timeout: 10_000)
```

After the timeout the socket is closed and the poller reports
`Runtime.ResponseFailed`; the invocation is over. The default is 30 s.

## Limits and billing

- First 6 MB stream uncapped, afterwards 2 MB/s.
- You are billed for the full duration even if the client disconnects; keep
  the function timeout as low as your use case allows.
- API Gateway REST/HTTP APIs do not stream Lambda responses; use Function URLs
  (optionally behind CloudFront) or the SDK.

## Testing locally

`Mayfly.LocalRuntime` understands streaming:

```elixir
{:ok, rt} = Mayfly.LocalRuntime.start_link()
{:ok, _} = Mayfly.start_link(handler: "MyApp.Stream", runtime_api: Mayfly.LocalRuntime.address(rt))

{:ok, %{body: body, headers: headers, trailers: trailers}} =
  Mayfly.LocalRuntime.invoke(rt, %{"prompt" => "hi"})

assert {"lambda-runtime-function-response-mode", "streaming"} in headers
assert trailers == %{}
```
