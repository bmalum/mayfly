defmodule Mayfly.Handler do
  @moduledoc """
  Handles the resolution and execution of Lambda function handlers.
  """

  @doc """
  Resolves the handler module and function from environment variables.
  Returns a tuple with {module, function}.

  ## Examples

      iex> System.put_env("_HANDLER", "Elixir.MyModule.my_function")
      iex> Mayfly.Handler.resolve()
      {MyModule, :my_function}
  """
  @spec resolve() :: {module(), atom()}
  def resolve do
    handler = System.get_env("_HANDLER") || "Elixir.Mayfly.Handler.default_handler"
    
    case String.split(handler, ".", trim: true) do
      parts when length(parts) < 2 ->
        require Logger
        Logger.error("Invalid handler format (expected Module.function): #{handler}")
        {Mayfly.Handler, :default_handler}
      
      parts ->
        function = parts |> List.last() |> String.to_existing_atom()
        module =
          parts
          |> Enum.drop(-1)
          |> Enum.join(".")
          |> String.to_existing_atom()
        
        {module, function}
    end
  rescue
    ArgumentError ->
      require Logger
      handler = System.get_env("_HANDLER") || "Elixir.Mayfly.Handler.default_handler"
      Logger.error("Handler not found or not loaded: #{handler}")
      {Mayfly.Handler, :default_handler}
  end

  @doc """
  Executes the handler function with the given payload.
  Handles proper error conversion and response formatting.
  """
  @spec execute(map(), {module(), atom()}) :: {:ok, any()} | {:error, map()}
  def execute(payload, {module, function}) do
    require Logger

    try do
      case Kernel.apply(module, function, [payload]) do
        {:error, error} -> {:error, Mayfly.Error.format_error(error)}
        {:ok, result} -> {:ok, result}
        other ->
          Logger.warning("Handler returned non-standard response (expected {:ok, result} or {:error, reason}): #{inspect(other)}")
          {:ok, other}
      end
    rescue
      e in UndefinedFunctionError ->
        {:error, Mayfly.Error.format_error(e, __STACKTRACE__)}
      e in RuntimeError ->
        {:error, Mayfly.Error.format_error(e, __STACKTRACE__)}
      e ->
        {:error, Mayfly.Error.format_error(e, __STACKTRACE__)}
    end
  end

  @doc """
  Default handler function used when no handler is specified.
  """
  @spec default_handler(map()) :: {:ok, String.t()}
  def default_handler(_payload) do
    {:ok, "Please provide a _HANDLER environment variable containing the function you would like to call prefixed with Elixir."}
  end
end
