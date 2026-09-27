defmodule Mayfly.RuntimeIntegrationTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Mayfly.{LocalRuntime, RuntimeAPI}

  defp start_runtime(handler, opts \\ []) do
    rt = start_supervised!({LocalRuntime, []}, id: make_ref())
    address = LocalRuntime.address(rt)

    result =
      Mayfly.start_link([handler: handler, runtime_api: address, name: nil] ++ opts)

    {rt, result}
  end

  test "happy path: JSON in, JSON out, invocation id echoed" do
    {rt, {:ok, _}} = start_runtime("Mayfly.Test.Handlers.Echo")

    assert {:ok, %{status: 200, body: body, headers: headers}} =
             LocalRuntime.invoke(rt, %{"hello" => "world"})

    assert JSON.decode!(body) == %{"hello" => "world"}
    assert {"content-type", "application/json"} in headers
    assert {"lambda-runtime-invocation-id", "inv-1"} in headers
  end

  test "context: request id, tenant id and init opts are visible to the handler" do
    {rt, {:ok, _}} = start_runtime("Mayfly.Test.Handlers.WithInit", handler_opts: [region: "eu"])

    {:ok, %{body: body}} =
      LocalRuntime.invoke(rt, %{}, headers: [{"Lambda-Runtime-Aws-Tenant-Id", "blue"}])

    assert %{
             "request_id" => "local-1-" <> _,
             "tenant_id" => "blue",
             "opts" => %{"region" => "eu"}
           } = JSON.decode!(body)

    assert System.get_env("_X_AMZN_TRACE_ID") =~ "Root=1-local"
  end

  test "errors: exception, exit, invalid response, unencodable result, bad JSON" do
    {rt, {:ok, _}} = start_runtime("Mayfly.Test.Handlers.Faulty")

    assert {:error,
            %{
              "errorType" => "ArgumentError",
              "errorMessage" => "bad argument",
              "stackTrace" => [_ | _]
            }} =
             LocalRuntime.invoke(rt, %{"mode" => "raise"})

    assert {:error, %{"errorType" => "Exit"}} = LocalRuntime.invoke(rt, %{"mode" => "exit"})

    assert {:error, %{"errorType" => "Runtime.InvalidResponse"}} =
             LocalRuntime.invoke(rt, %{"mode" => "bare"})

    assert {:error, %{"errorType" => "Runtime.InvalidResponse", "errorMessage" => msg}} =
             LocalRuntime.invoke(rt, %{"mode" => "unencodable"})

    assert msg =~ "could not be encoded"

    assert {:error, %{"errorType" => "Runtime.InvalidEvent"}} =
             LocalRuntime.invoke(rt, "{not json")

    # and the poller is still alive afterwards
    assert {:ok, %{body: ~s({"still":"alive"})}} = LocalRuntime.invoke(rt, %{"still" => "alive"})
  end

  test "binary response keeps its content type" do
    {rt, {:ok, _}} = start_runtime("Mayfly.Test.Handlers.Binary")
    assert {:ok, %{body: <<1, 2, 3>>, headers: headers}} = LocalRuntime.invoke(rt, %{})
    assert {"content-type", "application/octet-stream"} in headers
  end

  test "streaming response uses chunked encoding and the streaming header" do
    {rt, {:ok, _}} = start_runtime("Mayfly.Test.Handlers.Streaming")

    assert {:ok, %{body: "chunk1\nchunk2\nchunk3\n", headers: headers, trailers: %{}}} =
             LocalRuntime.invoke(rt, %{})

    assert {"lambda-runtime-function-response-mode", "streaming"} in headers
    assert {"transfer-encoding", "chunked"} in headers
    assert {"content-type", "text/plain"} in headers
  end

  test "mid-stream errors are reported via trailers" do
    {rt, {:ok, _}} = start_runtime("Mayfly.Test.Handlers.Streaming")

    assert {:ok, %{body: "chunk1\nchunk2\n", trailers: trailers}} =
             LocalRuntime.invoke(rt, %{"mode" => "midstream_error"})

    assert trailers["lambda-runtime-function-error-type"] == "Function.RuntimeError"

    assert %{"errorType" => "RuntimeError", "errorMessage" => "stream broke"} =
             trailers["lambda-runtime-function-error-body"] |> Base.decode64!() |> JSON.decode!()
  end

  test "function URL streaming prepends the HTTP prelude" do
    {rt, {:ok, _}} = start_runtime("Mayfly.Test.Handlers.Streaming")

    {:ok, %{body: body, headers: headers}} = LocalRuntime.invoke(rt, %{"mode" => "http"})
    assert {"content-type", "application/vnd.awslambda.http-integration-response"} in headers
    [prelude, payload] = String.split(body, <<0, 0, 0, 0, 0, 0, 0, 0>>)
    assert %{"statusCode" => 201, "cookies" => ["a=b"]} = JSON.decode!(prelude)
    assert payload == "abc"
  end

  test "init errors are posted to /runtime/init/error and start_link fails" do
    {rt, result} = start_runtime("Mayfly.Test.Handlers.InitFails")
    assert {:error, {:init_error, %{errorType: "Runtime.InitError"}}} = result

    assert %{"errorType" => "Runtime.InitError", "errorMessage" => msg} =
             LocalRuntime.init_error(rt)

    assert msg =~ "no database"

    {rt2, result2} = start_runtime("Nope.Missing")
    assert {:error, {:init_error, %{errorType: "Runtime.NoSuchHandler"}}} = result2
    assert %{"errorType" => "Runtime.NoSuchHandler"} = LocalRuntime.init_error(rt2)
  end

  test "concurrency: N pollers process invocations in parallel" do
    {rt, {:ok, sup}} = start_runtime("Mayfly.Test.Handlers.Faulty", concurrency: 4)
    assert length(Supervisor.which_children(sup)) == 4

    started = System.monotonic_time(:millisecond)

    results =
      1..4
      |> Task.async_stream(fn _ -> LocalRuntime.invoke(rt, %{"mode" => "slow"}) end,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    elapsed = System.monotonic_time(:millisecond) - started
    assert Enum.all?(results, &match?({:ok, %{body: ~s("done")}}, &1))
    # 4 × 200 ms sequentially would be ≥ 800 ms; parallel should be well under.
    assert elapsed < 600, "expected parallel processing, took #{elapsed} ms"
  end

  test "telemetry events are emitted" do
    parent = self()
    handler_id = {:test, make_ref()}

    :telemetry.attach_many(
      handler_id,
      [[:mayfly, :init, :stop], [:mayfly, :invocation, :start], [:mayfly, :invocation, :stop]],
      fn event, measurements, metadata, _ ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {rt, {:ok, _}} = start_runtime("Mayfly.Test.Handlers.Faulty")
    assert_receive {:telemetry, [:mayfly, :init, :stop], %{duration: _}, %{result: :ok}}

    LocalRuntime.invoke(rt, %{"mode" => "raise"})
    assert_receive {:telemetry, [:mayfly, :invocation, :start], _, %{context: %Mayfly.Context{}}}

    assert_receive {:telemetry, [:mayfly, :invocation, :stop], %{duration: _},
                    %{result: :error, error_type: "ArgumentError"}}
  end

  test "RuntimeAPI.endpoint/1" do
    assert RuntimeAPI.endpoint("127.0.0.1:9001") == {"127.0.0.1", 9001}
    assert RuntimeAPI.endpoint(nil) == nil
  end
end
