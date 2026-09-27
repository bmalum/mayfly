defmodule Mayfly do
  @moduledoc """
  Mayfly – an AWS Lambda custom runtime for Elixir.

  Nothing starts automatically. Inside Lambda the generated `bootstrap` runs
  `Mayfly.Boot.main/0`, which reads the environment and calls `start_link/1`.
  You can also start the runtime yourself (for example from your own
  supervision tree when using `Mayfly.LocalRuntime` in tests):

      Mayfly.start_link(handler: "MyApp.Handler", runtime_api: "127.0.0.1:9001")

  ## Options

    * `:handler` – `_HANDLER` string (module or `Module.function`); default
      `System.get_env("_HANDLER")`
    * `:runtime_api` – `host:port`; default `System.get_env("AWS_LAMBDA_RUNTIME_API")`
    * `:concurrency` – number of pollers; default `AWS_LAMBDA_MAX_CONCURRENCY` or 1
    * `:handler_opts` – passed to the handler's `init/1`; default `[]`
    * `:api` – module implementing `Mayfly.RuntimeAPI` (tests)
  """

  @doc """
  Resolves and initialises the handler, then starts the poller supervisor.

  Returns `{:error, {:init_error, payload}}` when the handler cannot be
  resolved or its `init/1` fails; the payload has already been posted to
  `/runtime/init/error` at that point.
  """
  @spec start_link(keyword()) ::
          Supervisor.on_start() | {:error, {:init_error, Mayfly.ErrorPayload.t()}}
  def start_link(opts \\ []) do
    Mayfly.Supervisor.start_link(opts)
  end

  @doc false
  def child_spec(opts), do: Mayfly.Supervisor.child_spec(opts)
end

defmodule Mayfly.Supervisor do
  @moduledoc """
  Starts one `Mayfly.Poller` per concurrency slot after the handler has been
  resolved and initialised exactly once.
  """

  use Supervisor

  require Logger

  alias Mayfly.{Handler, RuntimeAPI, Telemetry}

  @doc false
  def start_link(opts) do
    api = Keyword.get(opts, :api, RuntimeAPI)
    endpoint = endpoint!(opts)
    handler_string = Keyword.get_lazy(opts, :handler, fn -> System.get_env("_HANDLER") end)

    started = System.monotonic_time()
    resolution = Handler.resolve(handler_string, Keyword.get(opts, :handler_opts, []))

    Telemetry.execute(
      [:mayfly, :init, :stop],
      %{duration: System.monotonic_time() - started},
      %{handler: handler_string, result: elem(resolution, 0)}
    )

    case resolution do
      {:ok, handler} ->
        Logger.info(
          "Mayfly ready: handler #{inspect(handler.module)}, concurrency #{concurrency(opts)}"
        )

        Supervisor.start_link(
          __MODULE__,
          [api: api, endpoint: endpoint, handler: handler, concurrency: concurrency(opts)],
          name: Keyword.get(opts, :name, __MODULE__)
        )

      {:error, %{errorType: type, errorMessage: message} = payload} ->
        Logger.error("Initialisation failed: #{type}: #{message}")

        case api.init_error(endpoint, payload) do
          :ok -> :ok
          {:error, reason} -> Logger.error("Could not report init error: #{inspect(reason)}")
        end

        {:error, {:init_error, payload}}
    end
  end

  @impl true
  def init(opts) do
    children =
      for slot <- 0..(opts[:concurrency] - 1) do
        {Mayfly.Poller,
         api: opts[:api], endpoint: opts[:endpoint], handler: opts[:handler], slot: slot}
      end

    # A poller only stops on a container error, in which case the whole
    # runtime must exit; hence the low restart budget.
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 2, max_seconds: 5)
  end

  defp endpoint!(opts) do
    case Keyword.get_lazy(opts, :runtime_api, fn -> System.get_env("AWS_LAMBDA_RUNTIME_API") end) do
      nil ->
        raise ArgumentError,
              "AWS_LAMBDA_RUNTIME_API is not set and no :runtime_api option was given"

      value when is_binary(value) ->
        RuntimeAPI.endpoint(value)

      {_host, _port} = endpoint ->
        endpoint
    end
  end

  defp concurrency(opts) do
    case Keyword.get_lazy(opts, :concurrency, fn ->
           System.get_env("AWS_LAMBDA_MAX_CONCURRENCY")
         end) do
      nil -> 1
      n when is_integer(n) and n > 0 -> n
      s when is_binary(s) -> s |> String.to_integer() |> max(1)
    end
  end

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
  end
end
