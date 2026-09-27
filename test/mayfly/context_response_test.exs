defmodule Mayfly.ContextTest do
  use ExUnit.Case, async: true

  alias Mayfly.Context

  test "from_headers/2 maps all headers" do
    ctx =
      Context.from_headers(
        [
          {"lambda-runtime-aws-request-id", "req-1"},
          {"lambda-runtime-invocation-id", "inv-1"},
          {"lambda-runtime-deadline-ms", "1700000000000"},
          {"lambda-runtime-invoked-function-arn", "arn:aws:lambda:eu-central-1:1:function:f"},
          {"lambda-runtime-trace-id", "Root=1-abc"},
          {"lambda-runtime-aws-tenant-id", "blue"},
          {"lambda-runtime-client-context", "{}"},
          {"lambda-runtime-cognito-identity", "{}"}
        ],
        %{region: "eu-central-1"}
      )

    assert ctx == %Context{
             request_id: "req-1",
             invocation_id: "inv-1",
             deadline_ms: 1_700_000_000_000,
             function_arn: "arn:aws:lambda:eu-central-1:1:function:f",
             trace_id: "Root=1-abc",
             tenant_id: "blue",
             client_context: "{}",
             cognito_identity: "{}",
             env: %{region: "eu-central-1"}
           }
  end

  test "malformed or missing values are nil" do
    assert %Context{request_id: nil, deadline_ms: nil} =
             Context.from_headers([{"lambda-runtime-deadline-ms", "soon"}])
  end

  test "remaining_time_ms/1" do
    assert Context.remaining_time_ms(%Context{}) == nil
    future = System.system_time(:millisecond) + 10_000
    assert Context.remaining_time_ms(%Context{deadline_ms: future}) in 9_000..10_000
    assert Context.remaining_time_ms(%Context{deadline_ms: 1}) == 0
  end

  test "logger_metadata/1 skips nils" do
    assert Context.logger_metadata(%Context{request_id: "r", tenant_id: nil}) == [request_id: "r"]
  end
end

defmodule Mayfly.ResponseTest do
  use ExUnit.Case, async: true

  alias Mayfly.Response

  test "normalize/1 wraps plain values" do
    assert %Response{body: %{a: 1}, content_type: "application/json", mode: :buffered} =
             Response.normalize(%{a: 1})

    assert %Response{body: "x", content_type: "text/plain"} =
             Response.normalize(%Response{body: "x", content_type: "text/plain"})
  end

  test "encode_buffered/1 encodes JSON, passes binaries, rejects the rest" do
    assert {:ok, "application/json", io} =
             Response.encode_buffered(Response.normalize(%{a: [1, nil]}))

    assert IO.iodata_to_binary(io) == ~s({"a":[1,null]})

    assert {:ok, "image/png", <<1, 2>>} =
             Response.encode_buffered(%Response{body: <<1, 2>>, content_type: "image/png"})

    assert {:error, %Protocol.UndefinedError{}} =
             Response.encode_buffered(Response.normalize({:a, :b}))

    assert {:error, %ArgumentError{}} =
             Response.encode_buffered(%Response{body: %{}, content_type: "text/plain"})
  end

  test "stream_chunks/1 without http passes the body through" do
    r = %Response{body: ["a", "b"], content_type: "text/plain"} |> Response.stream()
    assert {"text/plain", ["a", "b"]} = Response.stream_chunks(r)
  end

  test "stream_chunks/1 with http prepends the prelude and 8 null bytes" do
    r =
      %Response{body: ["a", "b"], content_type: "text/plain"}
      |> Response.stream()
      |> Response.http(status: 201, headers: %{"x-test" => "1"}, cookies: ["c=d"])

    {ct, chunks} = Response.stream_chunks(r)
    assert ct == "application/vnd.awslambda.http-integration-response"

    [prelude, delimiter | rest] = Enum.to_list(chunks)
    assert delimiter == <<0, 0, 0, 0, 0, 0, 0, 0>>
    assert rest == ["a", "b"]

    assert %{
             "statusCode" => 201,
             "headers" => %{"x-test" => "1", "content-type" => "text/plain"},
             "cookies" => ["c=d"]
           } =
             prelude |> IO.iodata_to_binary() |> JSON.decode!()
  end
end
