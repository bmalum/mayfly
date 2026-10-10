defmodule Mayfly.Shutdown do
  @moduledoc """
  Graceful shutdown on `SIGTERM`.

  Lambda only tells a runtime that its execution environment is going away
  when an **external extension** is registered: it then sends `SIGTERM` to
  the runtime process and allows up to 2 s before `SIGKILL`. Without one, the
  environment is simply frozen and later discarded, and anything buffered in
  memory (log lines not yet written, metrics not yet flushed, a connection
  pool mid-request) is lost.

  Mayfly ships that extension as the layer `mayfly-shutdown-<arch>` (a few KB,
  see `layer/shutdown-extension/`). Attach it, and the runtime receives
  `SIGTERM`; this module turns the signal into:

  1. `:telemetry` event `[:mayfly, :shutdown]` with `%{reason: :sigterm}`;
  2. the hooks registered with `register/1` (your `init/1` can register one to
     drain a queue or close connections), each bounded by `:hook_timeout_ms`
     (1 s) and all of them together by `:deadline_ms` (1.2 s, inside Lambda's
     2 s window with room for the log flush);
  3. `Logger.flush/0`;
  4. `System.halt(0)`.

  `Mayfly.Boot.main/0` installs the handler automatically. Without the layer
  nothing changes: Lambda never sends the signal.

      def init(_opts) do
        Mayfly.Shutdown.register(fn -> MyApp.Metrics.flush() end)
        {:ok, nil}
      end
  """

  use GenServer

  require Logger

  alias Mayfly.Telemetry

  @hook_timeout_ms 1_000
  @deadline_ms 1_200

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc """
  Registers a zero-arity function to run on shutdown. Returns `:ok`.

  Outside Lambda (`mix lambda.invoke`, tests, `Mayfly.start_link/1` in your own
  supervision tree) the handler process may not exist; the call then logs at
  debug and returns `:ok`, so `init/1` code registering hooks works everywhere.
  """
  @spec register((-> any()), GenServer.server()) :: :ok
  def register(fun, server \\ __MODULE__) when is_function(fun, 0) do
    GenServer.call(server, {:register, fun})
  catch
    :exit, {:noproc, _} ->
      Logger.debug(
        "Mayfly.Shutdown is not running; hook not registered (no SIGTERM outside Lambda)"
      )

      :ok
  end

  @doc """
  Runs the shutdown sequence now (hooks, log flush, halt) as if `SIGTERM` had
  arrived. Used by the signal handler and by tests (pass `halt: fn _ -> :ok end`
  at start to keep the VM alive).
  """
  @spec run(GenServer.server()) :: :ok
  def run(server \\ __MODULE__), do: GenServer.call(server, :run, 10_000)

  @impl true
  def init(opts) do
    state = %{
      hooks: [],
      halt: Keyword.get(opts, :halt, &System.halt/1),
      hook_timeout_ms: Keyword.get(opts, :hook_timeout_ms, @hook_timeout_ms),
      deadline_ms: Keyword.get(opts, :deadline_ms, @deadline_ms),
      signals: Keyword.get(opts, :signals, true)
    }

    if state.signals do
      # Take SIGTERM away from the default handler (which stops the VM at
      # once) and have :erl_signal_server deliver it to us as a message.
      :ok = :os.set_signal(:sigterm, :handle)

      :ok =
        :gen_event.swap_handler(
          :erl_signal_server,
          {:erl_signal_handler, []},
          {__MODULE__.SignalHandler, self()}
        )
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:register, fun}, _from, state),
    do: {:reply, :ok, %{state | hooks: [fun | state.hooks]}}

  def handle_call(:run, _from, state) do
    shutdown(state, :manual)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sigterm, state) do
    shutdown(state, :sigterm)
    {:noreply, state}
  end

  defp shutdown(state, reason) do
    started = System.monotonic_time()
    Logger.info("Mayfly: shutdown (#{reason}), running #{length(state.hooks)} hook(s)")
    Telemetry.execute([:mayfly, :shutdown], %{}, %{reason: reason})

    deadline = started + System.convert_time_unit(state.deadline_ms, :millisecond, :native)

    state.hooks
    |> Enum.reverse()
    |> Enum.each(fn hook ->
      remaining =
        System.convert_time_unit(deadline - System.monotonic_time(), :native, :millisecond)

      if remaining > 0,
        do: run_hook(hook, min(state.hook_timeout_ms, remaining)),
        else: Logger.warning("Mayfly: shutdown deadline reached, skipping remaining hooks")
    end)

    Logger.flush()
    ms = System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)
    Logger.info("Mayfly: shutdown complete in #{ms} ms")
    Logger.flush()
    state.halt.(0)
  end

  # Hooks run unlinked so a crashing hook cannot take the shutdown down with it.
  defp run_hook(hook, timeout_ms) do
    {pid, ref} = spawn_monitor(fn -> hook.() end)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} ->
        :ok

      {:DOWN, ^ref, :process, ^pid, reason} ->
        Logger.warning("Mayfly: shutdown hook failed: #{inspect(reason)}")
    after
      timeout_ms ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        Logger.warning("Mayfly: shutdown hook timed out after #{timeout_ms} ms")
    end
  end

  defmodule SignalHandler do
    @moduledoc false
    # gen_event handler installed in :erl_signal_server; forwards SIGTERM to
    # Mayfly.Shutdown and leaves every other signal to the default behaviour.
    @behaviour :gen_event

    @impl true
    # swap_handler/3 calls init({args, result_of_old_terminate}).
    def init({pid, _old}) when is_pid(pid), do: {:ok, pid}
    def init(pid) when is_pid(pid), do: {:ok, pid}

    @impl true
    def handle_event(:sigterm, pid) do
      send(pid, :sigterm)
      {:ok, pid}
    end

    def handle_event(signal, pid) do
      :erl_signal_handler.handle_event(signal, [])
      {:ok, pid}
    end

    @impl true
    def handle_call(_req, pid), do: {:ok, :ok, pid}
    @impl true
    def handle_info(_msg, pid), do: {:ok, pid}
    @impl true
    def terminate(_reason, _pid), do: :ok
  end
end
