defmodule Mayfly.Extension do
  @moduledoc """
  Internal Lambda extension: registers with the Extensions API, subscribes to
  the Telemetry API, and turns platform telemetry into `:telemetry` events.

  Off by default. Enable with `MAYFLY_EXTENSION=1` (or `config :mayfly,
  extension: true` / the `:extension` option of `Mayfly.start_link/1`). When
  enabled, `Mayfly.Supervisor` registers the extension *before* the first
  `/next` poll, which is what Lambda requires of internal extensions, so the
  cost is one extra HTTP round trip plus the subscription at cold start.

  ## What you get

    * `:telemetry` events `[:mayfly, :platform, type]` for every platform
      record, with the record's `metrics` (numbers) as measurements and the
      full record plus `time` as metadata. `type` is the part after
      `platform.` as an atom: `:init_start`, `:init_runtime_done`,
      `:init_report`, `:start`, `:runtime_done`, `:report`, `:extension`,
      `:telemetry_subscription`, `:log_dropped`, ... `platform.report` carries
      `durationMs`, `billedDurationMs`, `memorySizeMB`, `maxMemoryUsedMB` and,
      on cold starts, `initDurationMs` – numbers the function cannot otherwise
      see about itself. `Mayfly.Metrics.attach_platform_metrics/2` publishes
      them as CloudWatch EMF metrics.
    * Every telemetry record is logged at `debug` level.

  What you do **not** get from this module: a `SHUTDOWN` hook. Lambda only
  delivers `SHUTDOWN` to *external* extensions; internal extensions
  registering for it are rejected with
  `ShutdownEventNotSupportedForInternalExtension`, so Mayfly registers for
  `INVOKE` only. Graceful shutdown is provided separately by `Mayfly.Shutdown`
  together with the `mayfly-shutdown` extension layer.

  ## How it works

  1. `POST /2020-01-01/extension/register` with `Lambda-Extension-Name: mayfly`
     and events `["INVOKE"]`; the response header
     `Lambda-Extension-Identifier` authenticates later calls.
  2. A `:gen_tcp` listener is opened on `sandbox.localdomain` (the only host
     the Telemetry API may deliver to) and `PUT /2022-07-01/telemetry`
     subscribes to `platform` events with a small buffer
     (`timeoutMs: 25, maxBytes: 262144, maxItems: 1000`).
  3. A process loops on `GET /2020-01-01/extension/event/next`. `INVOKE`
     events are acknowledged and otherwise ignored (the pollers handle
     invocations). Should Lambda ever deliver `SHUTDOWN` to an internal
     extension, Mayfly flushes `Logger` and halts.

  Telemetry is delivered *after* the invocation that produced it has
  completed (Lambda sends `platform.report` once the response is posted), so
  metrics derived from it are attributed by `requestId`, not by the current
  invocation. Nothing here runs in the request path.
  """

  use GenServer

  require Logger

  alias Mayfly.{HTTP, Telemetry}

  @extension_name "mayfly"
  @register_path "/2020-01-01/extension/register"
  @next_path "/2020-01-01/extension/event/next"
  @telemetry_path "/2022-07-01/telemetry"
  @id_header "lambda-extension-identifier"

  defstruct [:endpoint, :identifier, :listen, :port, :host, :halt]

  @doc "True when the extension should be started (env `MAYFLY_EXTENSION`, app env, or option)."
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts) do
    case Keyword.fetch(opts, :extension) do
      {:ok, value} -> value == true
      :error -> env_flag() || Application.get_env(:mayfly, :extension, false) == true
    end
  end

  defp env_flag do
    (System.get_env("MAYFLY_EXTENSION") || "")
    |> String.downcase()
    |> Kernel.in(~w(1 true yes on))
  end

  @doc false
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "The identifier Lambda assigned at registration (for tests and diagnostics)."
  @spec identifier(GenServer.server()) :: String.t()
  def identifier(server \\ __MODULE__), do: GenServer.call(server, :identifier)

  @doc "Port of the telemetry listener (for tests)."
  @spec listener_port(GenServer.server()) :: :inet.port_number()
  def listener_port(server \\ __MODULE__), do: GenServer.call(server, :port)

  # -- registration (synchronous, inside init so pollers start afterwards) ----------

  @impl true
  def init(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    # Lambda requires sandbox.localdomain as the destination host; it resolves
    # to the loopback interface inside the sandbox. Tests pass "127.0.0.1".
    host = Keyword.get(opts, :listener_host, "sandbox.localdomain")
    halt = Keyword.get(opts, :halt, &System.halt/1)

    with {:ok, identifier} <- register(endpoint),
         {:ok, listen, port} <- listen(),
         :ok <- subscribe(endpoint, identifier, host, port) do
      state = %__MODULE__{
        endpoint: endpoint,
        identifier: identifier,
        listen: listen,
        port: port,
        host: host,
        halt: halt
      }

      server = self()
      spawn_link(fn -> accept_loop(listen, server) end)
      spawn_link(fn -> event_loop(endpoint, identifier, server) end)
      Logger.debug("Mayfly extension registered (#{identifier}), telemetry on #{host}:#{port}")
      {:ok, state}
    else
      {:error, reason} -> {:stop, {:extension, reason}}
    end
  end

  defp register(endpoint) do
    # Internal extensions may only subscribe to INVOKE; Lambda answers 403
    # "ShutdownEventNotSupportedForInternalExtension" otherwise (verified).
    body = JSON.encode!(%{"events" => ["INVOKE"]})

    headers = [
      {"lambda-extension-name", @extension_name},
      {"content-type", "application/json"}
    ]

    case HTTP.post(endpoint, @register_path, headers, body, timeout: 5_000) do
      {:ok, %{status: 200, headers: resp_headers}} ->
        case List.keyfind(resp_headers, @id_header, 0) do
          {_, id} -> {:ok, id}
          nil -> {:error, :no_extension_identifier}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:register, status, body}}

      {:error, reason} ->
        {:error, {:register, reason}}
    end
  end

  defp listen do
    case :gen_tcp.listen(0, [
           :binary,
           packet: :raw,
           active: false,
           reuseaddr: true,
           # Telemetry is delivered from inside the sandbox over loopback.
           ip: {127, 0, 0, 1}
         ]) do
      {:ok, listen} ->
        {:ok, port} = :inet.port(listen)
        {:ok, listen, port}

      {:error, reason} ->
        {:error, {:listen, reason}}
    end
  end

  defp subscribe(endpoint, identifier, host, port) do
    body =
      JSON.encode!(%{
        "schemaVersion" => "2022-07-01",
        "types" => ["platform"],
        "buffering" => %{"timeoutMs" => 25, "maxBytes" => 262_144, "maxItems" => 1000},
        "destination" => %{"protocol" => "HTTP", "URI" => "http://#{host}:#{port}/telemetry"}
      })

    headers = [{@id_header, identifier}, {"content-type", "application/json"}]

    case HTTP.put(endpoint, @telemetry_path, headers, body, timeout: 5_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:subscribe, status, body}}
      {:error, reason} -> {:error, {:subscribe, reason}}
    end
  end

  @impl true
  def handle_call(:identifier, _from, state), do: {:reply, state.identifier, state}
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_info({:telemetry_batch, records}, state) do
    Enum.each(records, &dispatch/1)
    {:noreply, state}
  end

  def handle_info({:shutdown, record}, state) do
    Logger.info("Mayfly extension: SHUTDOWN (#{record["shutdownReason"]}), flushing logs")
    Telemetry.execute([:mayfly, :extension, :shutdown], %{}, %{record: record})
    Logger.flush()
    state.halt.(0)
    {:noreply, state}
  end

  def handle_info({:event_loop_error, reason, failures}, state) do
    Logger.warning("Mayfly extension: /event/next failed (#{failures}): #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:event_loop_dead, reason}, state) do
    Logger.error(
      "Mayfly extension: giving up on /event/next after repeated failures (#{inspect(reason)}); " <>
        "halting so Lambda recycles the environment instead of timing out every invocation"
    )

    Logger.flush()
    state.halt.(1)
    {:noreply, state}
  end

  # -- telemetry records -> :telemetry -----------------------------------------------

  @doc false
  def dispatch(%{"type" => "platform." <> type_str, "record" => record} = event) do
    Logger.debug("platform telemetry: #{inspect(event)}")
    type = type_str |> Macro.underscore() |> String.to_atom()

    measurements =
      record
      |> Map.get("metrics", %{})
      |> Enum.filter(fn {_k, v} -> is_number(v) end)
      |> Map.new(fn {k, v} -> {k |> Macro.underscore() |> String.to_atom(), v} end)

    Telemetry.execute([:mayfly, :platform, type], measurements, %{
      record: record,
      time: event["time"],
      request_id: record["requestId"],
      status: record["status"]
    })
  end

  def dispatch(other), do: Logger.debug("telemetry (ignored): #{inspect(other)}")

  # -- event loop (GET /event/next blocks until the next event) ------------------------

  # Lambda waits for every registered extension to call /event/next before it
  # completes an invocation, so this loop must never silently stop: transient
  # errors are retried with backoff, and after too many consecutive failures
  # the runtime halts (an environment without a working extension would hang
  # every invocation until timeout).
  @max_consecutive_failures 5

  defp event_loop(endpoint, identifier, server, failures \\ 0) do
    case HTTP.get(endpoint, @next_path, [{@id_header, identifier}]) do
      {:ok, %{status: 200, body: body}} ->
        case JSON.decode(body) do
          {:ok, %{"eventType" => "SHUTDOWN"} = record} ->
            send(server, {:shutdown, record})

          {:ok, _invoke} ->
            event_loop(endpoint, identifier, server, 0)

          {:error, reason} ->
            retry(endpoint, identifier, server, failures, {:bad_json, reason})
        end

      {:ok, %{status: status, body: body}} ->
        retry(endpoint, identifier, server, failures, {:http, status, body})

      {:error, reason} ->
        retry(endpoint, identifier, server, failures, reason)
    end
  end

  defp retry(endpoint, identifier, server, failures, reason) do
    failures = failures + 1
    send(server, {:event_loop_error, reason, failures})

    if failures >= @max_consecutive_failures do
      send(server, {:event_loop_dead, reason})
    else
      Process.sleep(min(100 * Integer.pow(2, failures), 2_000))
      event_loop(endpoint, identifier, server, failures)
    end
  end

  # -- telemetry listener (minimal HTTP/1.1 server, POST /telemetry with JSON array) -----

  defp accept_loop(listen, server) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        serve(socket, server)
        accept_loop(listen, server)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        # :emfile, :enfile, ... – back off and keep accepting rather than crash.
        Logger.warning("Mayfly extension: accept failed: #{inspect(reason)}")
        Process.sleep(200)
        accept_loop(listen, server)
    end
  end

  defp serve(socket, server) do
    with {:ok, head, rest} <- read_head(socket, ""),
         {:ok, length} <- content_length(head),
         {:ok, body} <- read_exact(socket, rest, length) do
      case JSON.decode(body) do
        {:ok, records} when is_list(records) -> send(server, {:telemetry_batch, records})
        _ -> Logger.debug("telemetry listener: undecodable body (#{byte_size(body)} bytes)")
      end

      :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    else
      _ ->
        :gen_tcp.send(
          socket,
          "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )
    end

    :gen_tcp.close(socket)
  end

  defp read_head(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      _ ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> read_head(socket, buffer <> data)
          error -> error
        end
    end
  end

  defp content_length(head) do
    case Regex.run(~r/^content-length:\s*(\d+)\s*$/im, head) do
      [_, n] -> {:ok, String.to_integer(n)}
      nil -> {:ok, 0}
    end
  end

  defp read_exact(_socket, buffer, len) when byte_size(buffer) >= len,
    do: {:ok, binary_part(buffer, 0, len)}

  defp read_exact(socket, buffer, len) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> read_exact(socket, buffer <> data, len)
      error -> error
    end
  end
end
