defmodule AWSLambda.Handler do
  @moduledoc """
  Handles the resolution and execution of Lambda function handlers.
  """

  @doc """
  Resolves the handler module and function from environment variables.
  Returns a tuple with {module, function}.

  ## Examples

      iex> System.put_env("_HANDLER", "Elixir.MyModule.my_function")
      iex> AWSLambda.Handler.resolve()
      {MyModule, :my_function}
  """
  @spec resolve() :: {module(), atom()}
  def resolve do
    handler = System.get_env("_HANDLER") || "Elixir.AWSLambda.default_handler"
    handler_split_list = handler |> String.split(".", trim: true)
    function = handler_split_list |> List.last() |> String.to_atom()
    module =
      handler_split_list
      |> List.delete_at(length(handler_split_list) - 1)
      |> Enum.join(".")
      |> String.to_atom()

    {module, function}
  end

  @doc """
  Executes the handler function with the given payload.
  Handles proper error conversion and response formatting.
  """
  @spec execute(map(), {module(), atom()}) :: {:ok, any()} | {:error, map()}
  def execute(payload, {module, function}) do
    try do
      case Kernel.apply(module, function, [payload]) do
        {:error, error} -> {:error, AWSLambda.Error.format_error(error)}
        {:ok, result} -> {:ok, result}
        other -> {:ok, other}  # Handle non-standard returns
      end
    rescue
      e in UndefinedFunctionError ->
        {:error, AWSLambda.Error.format_error(e, __STACKTRACE__)}
      e in RuntimeError ->
        {:error, AWSLambda.Error.format_error(e, __STACKTRACE__)}
      e ->
        {:error, AWSLambda.Error.format_error(e, __STACKTRACE__)}
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
