defmodule Mayfly.LocalRuntime do
  @moduledoc """
  A small Lambda Runtime API emulator for local development and tests.

  It speaks enough of the Runtime API for Mayfly (and any other custom
  runtime) to run against it: `GET /next` blocks until an event is queued,
  `/response` and `/error` deliver the outcome to whoever invoked, including
  streamed responses and error trailers.

      {:ok, rt} = Mayfly.LocalRuntime.start_link()
      {:ok, _} = Mayfly.start_link(handler: "MyApp.Handler", runtime_api: Mayfly.LocalRuntime.address(rt))

      Mayfly.LocalRuntime.invoke(rt, %{"name" => "world"})
      #=> {:ok, %{status: 200, body: ~s({"hello":"world"}), headers: [...]}}

      Mayfly.LocalRuntime.invoke(rt, %{"bad" => true})
      #=> {:error, %{"errorType" => "KeyError", "errorMessage" => ..., "stackTrace" => [...]}}

  Init errors are exposed through `init_error/1`. The emulator is
  single-tenant and does not enforce timeouts; it is a development aid, not a
  faithful Lambda simulation. For that, use
  [aws-lambda-rie](https://github.com/aws/aws-lambda-runtime-interface-emulator).
  """

  use GenServer

  @type invoke_result ::
          {:ok,
           %{status: 200, headers: [{String.t(), String.t()}], body: binary(), trailers: map()}}
          | {:error, map()}

  defstruct listen: nil,
            port: nil,
            queue: :queue.new(),
            waiting_pollers: :queue.new(),
            inflight: %{},
            init_error: nil,
            counter: 0

  # -- public API ---------------------------------------------------------------

  @doc "Starts the emulator on an ephemeral port (or `:port`)."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "`host:port` string suitable for `AWS_LAMBDA_RUNTIME_API`."
  @spec address(GenServer.server()) :: String.t()
  def address(rt), do: "127.0.0.1:#{GenServer.call(rt, :port)}"

  @doc """
  Queues `event` (any JSON-encodable term or a raw binary), waits for the
  runtime to process it and returns the outcome.
  """
  @spec invoke(GenServer.server(), term(), keyword()) :: invoke_result()
  def invoke(rt, event, opts \\ []) do
    body = if is_binary(event), do: event, else: JSON.encode!(event)
    timeout = Keyword.get(opts, :timeout, 30_000)
    headers = Keyword.get(opts, :headers, [])
    GenServer.call(rt, {:invoke, body, headers, timeout}, timeout + 1_000)
  end

  @doc "The payload posted to `/runtime/init/error`, if any."
  @spec init_error(GenServer.server()) :: map() | nil
  def init_error(rt), do: GenServer.call(rt, :init_error)

  # -- server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 0)
    {:ok, listen} = :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    server = self()
    spawn_link(fn -> accept_loop(listen, server) end)
    {:ok, %__MODULE__{listen: listen, port: port}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:init_error, _from, state), do: {:reply, state.init_error, state}

  def handle_call({:invoke, body, headers, timeout}, from, state) do
    id = state.counter + 1
    request_id = "local-#{id}-#{System.unique_integer([:positive])}"

    invocation = %{
      request_id: request_id,
      invocation_id: "inv-#{id}",
      deadline_ms: System.system_time(:millisecond) + timeout,
      body: body,
      extra_headers: headers
    }

    state = %{state | counter: id, inflight: Map.put(state.inflight, request_id, from)}
    {:noreply, dispatch(%{state | queue: :queue.in(invocation, state.queue)})}
  end

  # A poller connection is waiting for /next.
  def handle_call({:next, conn}, _from, state) do
    {:reply, :ok, dispatch(%{state | waiting_pollers: :queue.in(conn, state.waiting_pollers)})}
  end

  def handle_call({:result, request_id, result}, _from, state) do
    case Map.pop(state.inflight, request_id) do
      {nil, _} ->
        {:reply, :unknown, state}

      {from, inflight} ->
        GenServer.reply(from, result)
        {:reply, :ok, %{state | inflight: inflight}}
    end
  end

  def handle_call({:init_error, payload}, _from, state),
    do: {:reply, :ok, %{state | init_error: payload}}

  defp dispatch(state) do
    with {{:value, conn}, pollers} <- :queue.out(state.waiting_pollers),
         {{:value, invocation}, queue} <- :queue.out(state.queue) do
      send(conn, {:invocation, invocation})
      dispatch(%{state | waiting_pollers: pollers, queue: queue})
    else
      _ -> state
    end
  end

  # -- connection handling (one process per TCP connection) -------------------------

  defp accept_loop(listen, server) do
    {:ok, socket} = :gen_tcp.accept(listen)

    pid =
      spawn_link(fn ->
        receive do
          :go -> serve(socket, server)
        end
      end)

    :gen_tcp.controlling_process(socket, pid)
    send(pid, :go)
    accept_loop(listen, server)
  end

  defp serve(socket, server) do
    {:ok, method, path, headers, rest} = read_head(socket, "")
    body_result = read_body(socket, headers, rest)
    route(method, path, headers, body_result, socket, server)
    :gen_tcp.close(socket)
  end

  defp route(:get, "/2018-06-01/runtime/invocation/next", _h, _b, socket, server) do
    :ok = GenServer.call(server, {:next, self()})

    receive do
      {:invocation, inv} ->
        headers =
          [
            {"Lambda-Runtime-Aws-Request-Id", inv.request_id},
            {"Lambda-Runtime-Invocation-Id", inv.invocation_id},
            {"Lambda-Runtime-Deadline-Ms", Integer.to_string(inv.deadline_ms)},
            {"Lambda-Runtime-Invoked-Function-Arn",
             "arn:aws:lambda:local:000000000000:function:local"},
            {"Lambda-Runtime-Trace-Id", "Root=1-local-#{inv.invocation_id};Sampled=0"}
          ] ++ inv.extra_headers

        respond(socket, 200, headers, inv.body)
    end
  end

  defp route(:post, "/2018-06-01/runtime/invocation/" <> rest, headers, body, socket, server) do
    [request_id, action] = String.split(rest, "/", parts: 2)

    result =
      case {action, body} do
        {"response", {:ok, data, trailers}} ->
          {:ok, %{status: 200, headers: headers, body: data, trailers: trailers}}

        {"error", {:ok, data, _}} ->
          {:error, decode_error(data)}
      end

    GenServer.call(server, {:result, request_id, result})
    respond(socket, 202, [], ~s({"status":"OK"}))
  end

  defp route(:post, "/2018-06-01/runtime/init/error", _h, {:ok, data, _}, socket, server) do
    GenServer.call(server, {:init_error, decode_error(data)})
    respond(socket, 202, [], ~s({"status":"OK"}))
  end

  defp route(_method, path, _h, _b, socket, _server) do
    respond(socket, 404, [], ~s({"errorMessage":"unknown path #{path}"}))
  end

  defp decode_error(data) do
    case JSON.decode(data) do
      {:ok, map} -> map
      _ -> %{"errorType" => "Unknown", "errorMessage" => data, "stackTrace" => []}
    end
  end

  defp respond(socket, status, headers, body) do
    lines = for {k, v} <- headers, do: [k, ": ", v, "\r\n"]

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} #{reason(status)}\r\n",
      "Content-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n",
      lines,
      "\r\n",
      body
    ])
  end

  defp reason(200), do: "OK"
  defp reason(202), do: "Accepted"
  defp reason(_), do: "Error"

  # -- HTTP parsing ----------------------------------------------------------------

  defp read_head(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        [request_line | header_lines] = String.split(head, "\r\n")
        [method, path, _] = String.split(request_line, " ", parts: 3)

        headers =
          for line <- header_lines, [k, v] = :binary.split(line, ":") do
            {k |> String.trim() |> String.downcase(), String.trim(v)}
          end

        {:ok, method |> String.downcase() |> String.to_atom(), path, headers, rest}

      [_] ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 30_000)
        read_head(socket, buffer <> more)
    end
  end

  defp read_body(socket, headers, buffer) do
    cond do
      List.keyfind(headers, "transfer-encoding", 0) |> chunked?() ->
        read_chunked(socket, buffer, [])

      match?({_, _}, List.keyfind(headers, "content-length", 0)) ->
        {_, len} = List.keyfind(headers, "content-length", 0)
        {:ok, read_exact(socket, buffer, String.to_integer(len)), %{}}

      true ->
        {:ok, buffer, %{}}
    end
  end

  defp chunked?({_, v}), do: String.contains?(v, "chunked")
  defp chunked?(nil), do: false

  defp read_exact(_socket, buffer, len) when byte_size(buffer) >= len,
    do: binary_part(buffer, 0, len)

  defp read_exact(socket, buffer, len) do
    {:ok, more} = :gen_tcp.recv(socket, 0, 30_000)
    read_exact(socket, buffer <> more, len)
  end

  defp read_chunked(socket, buffer, acc) do
    case :binary.split(buffer, "\r\n") do
      [size_line, rest] ->
        size = size_line |> String.split(";") |> hd() |> String.to_integer(16)

        if size == 0 do
          trailers = read_trailers(socket, rest, %{})
          {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), trailers}
        else
          {chunk, rest} = take(socket, rest, size)
          read_chunked(socket, rest, [chunk | acc])
        end

      [_] ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 30_000)
        read_chunked(socket, buffer <> more, acc)
    end
  end

  defp take(_socket, buffer, size) when byte_size(buffer) >= size + 2 do
    <<chunk::binary-size(^size), "\r\n", rest::binary>> = buffer
    {chunk, rest}
  end

  defp take(socket, buffer, size) do
    {:ok, more} = :gen_tcp.recv(socket, 0, 30_000)
    take(socket, buffer <> more, size)
  end

  defp read_trailers(socket, buffer, acc) do
    case :binary.split(buffer, "\r\n") do
      ["", _] ->
        acc

      [line, rest] ->
        [k, v] = :binary.split(line, ":")

        read_trailers(
          socket,
          rest,
          Map.put(acc, k |> String.trim() |> String.downcase(), String.trim(v))
        )

      [_] ->
        case :gen_tcp.recv(socket, 0, 1_000) do
          {:ok, more} -> read_trailers(socket, buffer <> more, acc)
          _ -> acc
        end
    end
  end
end
