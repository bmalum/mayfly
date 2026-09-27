defmodule Mayfly.Poller do
  @moduledoc """
  One poller owns one concurrency slot: it long-polls `/runtime/invocation/next`,
  runs the handler and posts the result, then polls again.

  Standard Lambda runs exactly one poller. On Lambda Managed Instances
  `Mayfly.Supervisor` starts `AWS_LAMBDA_MAX_CONCURRENCY` of them; each poller
  is an independent process, so invocations never share state except the
  handler state returned from `init/1`.

  Poll failures are retried with exponential backoff (100 ms to 5 s) and
  emit `[:mayfly, :poll, :error]`. Non-recoverable Runtime API answers
  (HTTP 500 "container error") stop the poller, which makes the supervisor
  shut the VM down as the Runtime API contract requires.
  """

  use GenServer

  require Logger

  alias Mayfly.{Context, ErrorPayload, Handler, Response, RuntimeAPI, Telemetry}

  @initial_backoff_ms 100
  @max_backoff_ms 5_000

  defstruct [:api, :endpoint, :handler, :env, :slot, backoff_ms: 0]

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc false
  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.get(opts, :slot, 0)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      api: Keyword.get(opts, :api, RuntimeAPI),
      endpoint: Keyword.fetch!(opts, :endpoint),
      handler: Keyword.fetch!(opts, :handler),
      env: Keyword.get_lazy(opts, :env, &Context.env_from_system/0),
      slot: Keyword.get(opts, :slot, 0)
    }

    Logger.metadata(poller: state.slot)
    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, %__MODULE__{} = state) do
    case state.api.next_invocation(state.endpoint) do
      {:ok, %{headers: headers, body: body}} ->
        process(Context.from_headers(headers, state.env), body, state)
        send(self(), :poll)
        {:noreply, %{state | backoff_ms: 0}}

      {:error, {:http, 500, body}} ->
        Logger.error("Runtime API reported a container error, stopping: #{body}")
        {:stop, {:container_error, body}, state}

      {:error, reason} ->
        backoff = next_backoff(state.backoff_ms)
        Telemetry.execute([:mayfly, :poll, :error], %{backoff_ms: backoff}, %{reason: reason})

        Logger.error(
          "Failed to fetch next invocation (retry in #{backoff} ms): #{inspect(reason)}"
        )

        Process.send_after(self(), :poll, backoff)
        {:noreply, %{state | backoff_ms: backoff}}
    end
  end

  def handle_info(message, state) do
    Logger.warning("Mayfly.Poller ignoring unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  # -- invocation ----------------------------------------------------------------

  defp process(%Context{request_id: nil}, _body, _state) do
    Logger.error("Invocation without Lambda-Runtime-Aws-Request-Id header, skipping")
  end

  defp process(%Context{} = ctx, body, state) do
    if ctx.trace_id, do: System.put_env("_X_AMZN_TRACE_ID", ctx.trace_id)
    Logger.metadata(Context.logger_metadata(ctx))

    Telemetry.span([:mayfly, :invocation], %{context: ctx}, fn ->
      outcome =
        with {:ok, event} <- decode(body),
             {:ok, %Response{} = response} <- Handler.invoke(state.handler, event, ctx) do
          {:ok, state.api.invocation_response(state.endpoint, ctx, response)}
        else
          {:error, %{errorType: _} = payload} ->
            {:error, payload, state.api.invocation_error(state.endpoint, ctx, payload)}
        end

      report(outcome, ctx)
    end)

    Logger.metadata(request_id: nil, tenant_id: nil, trace_id: nil)
  end

  defp report({:ok, :ok}, _ctx), do: {:ok, %{result: :ok, error_type: nil}}

  defp report({:ok, {:error, reason}}, ctx) do
    Logger.error("Failed to post response for #{ctx.request_id}: #{inspect(reason)}")
    {:ok, %{result: :error, error_type: "Runtime.ResponseFailed"}}
  end

  defp report({:error, payload, post_result}, ctx) do
    Logger.error(
      "Invocation #{ctx.request_id} failed: #{payload.errorType}: #{payload.errorMessage}"
    )

    case post_result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to post error for #{ctx.request_id}: #{inspect(reason)}")
    end

    {:ok, %{result: :error, error_type: payload.errorType}}
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, event} ->
        {:ok, event}

      {:error, reason} ->
        {:error,
         ErrorPayload.runtime(
           "InvalidEvent",
           "Invocation payload is not valid JSON: #{inspect(reason)}"
         )}
    end
  end

  defp next_backoff(0), do: @initial_backoff_ms
  defp next_backoff(current), do: min(current * 2, @max_backoff_ms)
end
