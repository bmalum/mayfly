defmodule Mayfly.Handler do
  @moduledoc """
  Behaviour for Lambda function handlers.

      defmodule MyApp.Handler do
        use Mayfly.Handler

        @impl true
        def init(_opts) do
          # cold-start work: read config, open a pool, warm a cache
          {:ok, %{table: System.fetch_env!("TABLE_NAME")}}
        end

        @impl true
        def handle(event, %Mayfly.Context{} = ctx, state) do
          {:ok, %{table: state.table, request_id: ctx.request_id, event: event}}
        end
      end

  Set the Lambda **Handler** (`_HANDLER`) to the module name: `MyApp.Handler`.

  ## Callbacks

    * `c:init/1` – optional, runs once per execution environment before the
      first `/next` poll. Return `{:ok, state}` or `{:error, reason}`; an error
      is reported as `Runtime.InitError` and the function fails to start. The
      default returns `{:ok, nil}`.
    * `c:handle/3` – called for every invocation with the decoded event, the
      `Mayfly.Context` and the state from `init/1`. Return `{:ok, response}`
      or `{:error, reason}`. See `Mayfly.Response` for what `response` may be.

  On Lambda Managed Instances `handle/3` runs concurrently in separate
  processes (up to `AWS_LAMBDA_MAX_CONCURRENCY`); state is shared read-only.

  ## Legacy `Module.function` handlers

  `_HANDLER=MyApp.Legacy.handle` still works: a public function of arity 1
  (`handle(event)`) or 2 (`handle(event, context)`) is wrapped automatically.
  The `Elixir.` prefix is accepted in both forms.
  """

  alias Mayfly.{Context, ErrorPayload, Response}

  @type state :: term()
  @type result :: {:ok, Response.t() | term()} | {:error, term()}

  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}
  @callback handle(event :: term(), context :: Context.t(), state :: state()) :: result()

  @optional_callbacks init: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour Mayfly.Handler

      @impl Mayfly.Handler
      def init(_opts), do: {:ok, nil}

      defoverridable init: 1
    end
  end

  @typedoc "A resolved, ready-to-call handler."
  @type resolved :: %{
          module: module(),
          fun: (term(), Context.t(), state() -> result()),
          state: state()
        }

  @doc """
  Resolves the `_HANDLER` string and runs `init/1`.

  Returns `{:error, %{errorType: "Runtime.NoSuchHandler" | "Runtime.InitError", ...}}`
  on failure so callers can post it to `/runtime/init/error` directly.
  """
  @spec resolve(String.t() | nil, keyword()) :: {:ok, resolved()} | {:error, ErrorPayload.t()}
  def resolve(handler, opts \\ [])

  def resolve(nil, _opts),
    do:
      {:error,
       ErrorPayload.runtime(
         "NoSuchHandler",
         "_HANDLER is not set (expected Module or Module.function)"
       )}

  def resolve(handler, opts) when is_binary(handler) do
    parts = handler |> String.split(".", trim: true) |> Enum.reject(&(&1 == "Elixir"))

    with {:ok, module, fun, kind} <- locate(parts, handler),
         {:ok, state} <- run_init(module, kind, opts) do
      {:ok, %{module: module, fun: fun, state: state}}
    end
  end

  @doc "Invokes a resolved handler, converting exceptions, exits and throws into error payloads."
  @spec invoke(resolved(), term(), Context.t()) ::
          {:ok, Response.t()} | {:error, ErrorPayload.t()}
  def invoke(%{fun: fun, state: state}, event, %Context{} = ctx) do
    case fun.(event, ctx, state) do
      {:ok, response} -> {:ok, Response.normalize(response)}
      {:error, reason} -> {:error, ErrorPayload.from_term(reason)}
      other -> {:error, invalid_response(other)}
    end
  rescue
    e -> {:error, ErrorPayload.from_term(e, __STACKTRACE__)}
  catch
    kind, reason -> {:error, ErrorPayload.from_caught(kind, reason, __STACKTRACE__)}
  end

  # -- resolution --------------------------------------------------------------

  defp locate([], handler), do: {:error, no_such_handler("Invalid handler #{inspect(handler)}")}

  defp locate(parts, handler) do
    module = Module.concat(parts)

    cond do
      Code.ensure_loaded?(module) and function_exported?(module, :handle, 3) ->
        {:ok, module, &module.handle/3, :behaviour}

      Code.ensure_loaded?(module) ->
        {:error,
         no_such_handler(
           "#{inspect(module)} does not implement Mayfly.Handler (handle/3 not exported)"
         )}

      length(parts) >= 2 ->
        locate_function(Enum.drop(parts, -1), List.last(parts), handler)

      true ->
        {:error, no_such_handler("Handler module #{inspect(module)} could not be loaded")}
    end
  end

  defp locate_function(module_parts, function_name, handler) do
    module = Module.concat(module_parts)

    if Code.ensure_loaded?(module) do
      try do
        fun = String.to_existing_atom(function_name)

        cond do
          function_exported?(module, fun, 2) ->
            {:ok, module, fn event, ctx, _state -> apply(module, fun, [event, ctx]) end, :legacy}

          function_exported?(module, fun, 1) ->
            {:ok, module, fn event, _ctx, _state -> apply(module, fun, [event]) end, :legacy}

          true ->
            {:error, no_such_handler(not_exported(module, function_name))}
        end
      rescue
        ArgumentError -> {:error, no_such_handler(not_exported(module, function_name))}
      end
    else
      {:error,
       no_such_handler(
         "Handler #{inspect(handler)} not found: neither module #{inspect(Module.concat(module_parts ++ [function_name]))} " <>
           "nor module #{inspect(module)} could be loaded"
       )}
    end
  end

  defp not_exported(module, name),
    do:
      "#{inspect(module)} does not export #{name}/1 or #{name}/2 and does not implement Mayfly.Handler"

  defp no_such_handler(message), do: ErrorPayload.runtime("NoSuchHandler", message)

  defp run_init(_module, :legacy, _opts), do: {:ok, nil}

  # Only Mayfly.Handler modules have an init/1 contract; a legacy `Module.function`
  # handler may define init/1 for an unrelated reason (GenServer, Plug).
  defp run_init(module, :behaviour, opts) do
    if function_exported?(module, :init, 1) do
      try do
        case module.init(opts) do
          {:ok, state} ->
            {:ok, state}

          {:error, reason} ->
            {:error, init_error(ErrorPayload.from_term(reason))}

          other ->
            {:error,
             init_error(ErrorPayload.from_term("init/1 returned #{inspect(other, limit: 20)}"))}
        end
      rescue
        e -> {:error, init_error(ErrorPayload.from_term(e, __STACKTRACE__))}
      catch
        kind, reason ->
          {:error, init_error(ErrorPayload.from_caught(kind, reason, __STACKTRACE__))}
      end
    else
      {:ok, nil}
    end
  end

  defp init_error(%{errorMessage: message} = payload),
    do: %{payload | errorType: "Runtime.InitError", errorMessage: "init/1 failed: " <> message}

  defp invalid_response(value) do
    ErrorPayload.runtime(
      "InvalidResponse",
      "Handler must return {:ok, response} or {:error, reason}, got: " <>
        inspect(value, limit: 50, printable_limit: 500)
    )
  end
end
