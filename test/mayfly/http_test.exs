defmodule Mayfly.HTTPTest do
  use ExUnit.Case, async: true

  alias Mayfly.HTTP

  # Raw TCP stub: captures the full request and replies with a canned response.
  defp stub(response_fun) do
    owner = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      request = collect(socket, "")
      send(owner, {:request, request})
      :gen_tcp.send(socket, response_fun.(request))
      :gen_tcp.close(socket)
    end)

    {"127.0.0.1", port}
  end

  # Read until the request is complete (content-length or terminating chunk).
  defp collect(socket, acc) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
    acc = acc <> data

    complete? =
      cond do
        String.contains?(acc, "transfer-encoding: chunked") ->
          String.ends_with?(acc, "0\r\n\r\n") or Regex.match?(~r/\r\n0\r\n(.*\r\n)*\r\n$/s, acc)

        String.contains?(acc, "\r\n\r\n") ->
          [head, body] = String.split(acc, "\r\n\r\n", parts: 2)

          case Regex.run(~r/content-length: (\d+)/i, head) do
            [_, n] -> byte_size(body) >= String.to_integer(n)
            nil -> true
          end

        true ->
          false
      end

    if complete?, do: acc, else: collect(socket, acc)
  end

  defp ok(body, extra),
    do:
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n#{extra}Content-Length: #{byte_size(body)}\r\n\r\n#{body}"

  test "GET parses status, lowercased headers and content-length body" do
    endpoint = stub(fn _ -> ok(~s({"a":1}), "Lambda-Runtime-Aws-Request-Id: req-1\r\n") end)

    assert {:ok, %{status: 200, headers: headers, body: ~s({"a":1})}} = HTTP.get(endpoint, "/x")
    assert {"lambda-runtime-aws-request-id", "req-1"} in headers
    assert_receive {:request, req}
    assert req =~ "GET /x HTTP/1.1\r\n"
    assert req =~ "user-agent: mayfly/"
  end

  test "reads a body split across packets and a chunked response body" do
    endpoint =
      stub(fn _ ->
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
      end)

    assert {:ok, %{body: "hello world"}} = HTTP.get(endpoint, "/chunked")
  end

  test "reads until close when no length is given" do
    endpoint = stub(fn _ -> "HTTP/1.1 500 Error\r\n\r\nno length" end)
    assert {:ok, %{status: 500, body: "no length"}} = HTTP.get(endpoint, "/")
  end

  test "POST sends content-length and body" do
    endpoint = stub(fn _ -> "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n" end)

    assert {:ok, %{status: 202, body: ""}} =
             HTTP.post(endpoint, "/p", [{"content-type", "application/json"}], ~s({"b":2}))

    assert_receive {:request, req}
    assert req =~ "POST /p HTTP/1.1\r\n"
    assert req =~ "content-length: 7\r\n"
    assert req =~ "content-type: application/json\r\n"
    assert String.ends_with?(req, "\r\n\r\n{\"b\":2}")
  end

  test "post_chunked writes chunks, skips empty ones and terminates without trailers" do
    endpoint = stub(fn _ -> "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n" end)

    assert {:ok, %{status: 202}} = HTTP.post_chunked(endpoint, "/s", [], ["ab", "", "cde"])
    assert_receive {:request, req}
    assert req =~ "transfer-encoding: chunked\r\n"
    refute req =~ "trailer:"
    assert String.ends_with?(req, "\r\n\r\n2\r\nab\r\n3\r\ncde\r\n0\r\n\r\n")
  end

  test "post_chunked announces and sends trailers when the stream raises" do
    endpoint = stub(fn _ -> "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n" end)

    stream =
      Stream.map([1, 2, 3], fn
        3 -> raise "kaput"
        n -> "#{n}"
      end)

    trailer_fun = fn
      :ok -> [{"X-Ok", "1"}]
      {:error, %RuntimeError{message: m}, _st} -> [{"X-Err", m}]
    end

    assert {:ok, %{status: 202}} =
             HTTP.post_chunked(endpoint, "/s", [], stream,
               trailer_names: ["X-Err", "X-Ok"],
               trailer_fun: trailer_fun
             )

    assert_receive {:request, req}
    assert req =~ "trailer: X-Err, X-Ok\r\n"
    assert String.ends_with?(req, "1\r\n1\r\n1\r\n2\r\n0\r\nX-Err: kaput\r\n\r\n")
  end

  test "connection refused is an error tuple" do
    assert {:error, :econnrefused} = HTTP.get({"127.0.0.1", 1}, "/", [], timeout: 1_000)
  end
end

defmodule Mayfly.HTTPBackpressureTest do
  use ExUnit.Case, async: true

  test "a stalled consumer trips send_timeout instead of blocking forever" do
    # Accept but never read: kernel buffers fill, then gen_tcp.send blocks.
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, recbuf: 4096])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, _s} = :gen_tcp.accept(listen)
      Process.sleep(:infinity)
    end)

    big = Stream.repeatedly(fn -> :binary.copy("x", 64 * 1024) end)
    started = System.monotonic_time(:millisecond)

    result =
      Mayfly.HTTP.post_chunked({"127.0.0.1", port}, "/", [], big,
        send_timeout: 500,
        timeout: 2_000
      )

    elapsed = System.monotonic_time(:millisecond) - started
    assert {:error, reason} = result
    assert reason in [:timeout, :closed, :closed_before_complete, :econnreset]
    assert elapsed < 5_000, "took #{elapsed} ms"
  end
end
